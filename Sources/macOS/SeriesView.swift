import JellyfinKit
import SwiftUI

/// Series page. Same header as the movie page, with three sections below:
/// Episodes, Cast, Similar.
///
/// Behavior matches the iPhone version:
/// - The season pill opens a list directly below it, not a separate window or
///   a sheet from the bottom. The current season has a checkmark.
/// - The tabs switch the section below without scrolling.
/// - An episode starts at its own position.
struct SeriesView: View {
    let model: AppModel
    let series: Item
    /// Season selected on open; set when the user arrived via an episode.
    var startSeasonID: String?
    /// The season **number** of the episode the user came from: the reliable key.
    ///
    /// The server may return no `SeasonId` for an episode. Id comparisons then find
    /// nothing and the selection falls back to the first season. The number is
    /// always present.
    var startSeasonNumber: Int?
    let back: () -> Void
    @Environment(Navigator.self) private var navigator
    @Environment(\.section) private var section

    @State private var tab: PageTab = .episodes
    @State private var seasons: [Item] = []
    @State private var selected: Item?
    @State private var episodes: [Item] = []
    /// **Empty and failed are two different states.** Checking only the list made
    /// "Keine Folgen" appear even when the server had not answered.
    @State private var episodesDisturbed = false
    @State private var seasonsDisturbed = false
    @State private var similar: [Item] = []
    @State private var similarDisturbed = false
    /// Extras of the series; empty means no tab.
    @State private var extras: [Item] = []
    @State private var seasonOpen = false
    @State private var seasonPanelOpen = false
    @State private var loadItem: [DownloadItem] = []
    /// What the header panel shows: "Staffel 5" or the name of an episode.
    /// It used to be fixed to the season even when only one episode was loaded.
    @State private var loadTitle = ""
    /// The download selection: whole series, seasons, episodes.
    @State private var selectionOpen = false
    /// For the header image, which is saved along with a download on the Mac.
    @Environment(\.displayScale) private var pixelMetric
    @State private var pagesWidth: CGFloat = 0

    // MARK: Downloads

    /// A `DownloadItem` for an episode. **The same source the player would use**,
    /// since it is the same file.
    private func entries(_ episode: Item) -> DownloadItem? {
        guard let account = model.session?.userID else { return nil }
        let source = episode.mediaSources?.first
        return DownloadItem(
            id: episode.id, account: account, art: .episode, title: episode.name,
            series: series.name, seriesIdentifier: series.id,
            season: episode.parentIndexNumber ?? selected?.indexNumber,
            episode: episode.indexNumber,
            runtimeTicks: episode.runTimeTicks, container: source?.container,
            source: source?.id, bytes: source?.size ?? 0,
            watchState: episode.userData, videoCodec: source?.videoCodec)
    }

    /// The series poster plus the landscape image of each episode being loaded.
    private var loadImages: [String: URL] {
        var card: [String: URL] = [:]
        // Poster at 600 high instead of the 300 of a tile, as on the iPhone.
        if let poster = model.imageURL(for: series, maxHeight: 600, portrait: true) {
            card[series.id] = poster
        }
        // **Header image at screen resolution**, for the series page in Downloads.
        // There it is shown as `Backdrop`: 62 % of the width, `heroHeightValue * 1.62`
        // high. A 16:9 image needs at least that much width for this. Multiplied by
        // the display scale to stay sharp.
        if let header = model.headerImageURL(for: series, width: DownloadSeriesOverviewPage.headerPixel(
            pagesWidth: pagesWidth, pixelMetric: pixelMetric)) {
            card[DownloadManager.headerKey(series.id)] = header
        }
        // **Every selected episode, not only those of the open season.** The download
        // selection can take whole series, so `loadItem` holds episodes from seasons
        // this page is not showing. The series store fetches their images.
        for p in loadItem {
            let f = episodes.first(where: { $0.id == p.id })
                ?? SeriesCache.shared.state(series.id, with: model)?
                    .episodes.values.flatMap { $0 }.first(where: { $0.id == p.id })
            if let f, let image = model.imageURL(for: f, maxHeight: 220) {
                card[p.id] = image
            }
        }
        return card
    }

    // There is no `folgeGeklickt` and no download ring on each episode row, as on
    // the iPhone. To download a single episode, tick it in the download selection,
    // which also shows its size.

    /// **The selection result goes to the download panel.** The panel still handles
    /// free space, Wi-Fi and the normal case; the selection is a step before it.
    private func selectionLoad(_ selectedEpisodes: [Item], _ quality: DownloadQuality) {
        loadItem = selectedEpisodes.compactMap { entries($0)?.inQuality(quality) }
        guard !loadItem.isEmpty else { return }
        loadTitle = series.name
        withAnimation(Theme.leap) { seasonPanelOpen = true }
    }
    @State private var loads = true
    /// Whether the first pass of `load()` has finished. **Without it the load ran
    /// twice:** `.task(id: selected?.id)` fires on appear and fetched the episodes
    /// alongside `load()`. When its response arrived shortly after, the whole list
    /// was built a second time, in the middle of the push transition.
    @State private var firstPull = false
    /// The season whose episodes are shown or being fetched. When `load()` sets the
    /// selection, `.task(id:)` sees the change and must not fetch again what the
    /// same pass already delivered.
    @State private var episodesFor: String?

    /// **The initial state comes from the cache, not from nothing.**
    ///
    /// Same rule as in `NetworkImage` and on tvOS: a value supplied later arrives too
    /// late. The empty pass has already happened, and that pass is the loader that
    /// gets replaced by the list in the middle of the push transition.
    @MainActor init(model: AppModel, series: Item,
                    startSeasonID: String? = nil, startSeasonNumber: Int? = nil,
                    back: @escaping () -> Void) {
        self.model = model
        self.series = series
        self.startSeasonID = startSeasonID
        self.startSeasonNumber = startSeasonNumber
        self.back = back

        let remembered = SeriesCache.shared.state(series.id, with: model)
        let seasons = remembered?.seasons ?? []
        _seasons = State(initialValue: seasons)

        // **Only what was passed in.** If a hint is given it applies immediately, so the
        // right season is already in the first frame. If none is given the selection
        // stays open: `load` then asks which season the user is in, and that one
        // applies. Taking `seasons.first` here would show season 1 and swap it for
        // the current season a moment later, which is exactly the flicker this rule
        // avoids.
        let season = seasons.first { $0.id == startSeasonID }
            ?? seasons.first { $0.indexNumber != nil && $0.indexNumber == startSeasonNumber }
        _selected = State(initialValue: season)

        let episodes = season.flatMap { remembered?.episodes[$0.id] } ?? []
        _episodes = State(initialValue: episodes)
        _loads = State(initialValue: episodes.isEmpty)
    }
    @State private var headerState = HeaderState()

    enum PageTab: String, CaseIterable {
        case episodes = "folgen", cast = "besetzung", similarOne = "aehnliches", extras

        var label: LocalizedStringKey {
            switch self {
            case .episodes:     "Folgen"
            case .cast:  "Besetzung"
            case .similarOne: "Ähnliches"
            case .extras:     "Extras"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DetailHero(model: model, title: series, state: headerState,
                           season: selected,
                           // **The download button sits in the row below the play button**, as on the
                           // iPhone, not in a chip next to the season picker where nobody looks for it.
                           // The selection itself stays here because it needs the seasons and the
                           // preloaded episodes.
                           loadSelection: {
                               withAnimation(Theme.leap) { selectionOpen.toggle() }
                           },
                           selectionOpen: selectionOpen)
                    // **The header draws above what comes after it.**
                    //
                    // Without this the More menu ends up behind the tab row and the episode list:
                    // they come after the header in the stack, so they draw later and therefore on
                    // top. Both showed through each other.
                    .zIndex(1)

                TabRail(pick: $tab, cases: extras.isEmpty ? [.episodes, .cast, .similarOne]
                                                                    : SeriesView.PageTab.allCases)
                    .padding(.top, 26)

                segment
                    .padding(.horizontal, Theme.edgeSpacing)
                    .padding(.top, 20)
            }
            .padding(.bottom, 40)
            // **The color of the header image under the page**, as on the movie page and the
            // iPhone (`MoodReason`). It sits on the content so it scrolls with the
            // header; buttons, season pill and list pick it up through `onImageTint`.
            .background(alignment: .top) {
                MoodReason(url: model.headerImageURL(for: series), since: Theme.heroHeightValue)
            }
            .environment(\.onImageTint, true)
            .environment(\.imageColorSource, model.headerImageURL(for: series))
            // **The download panel lives in the content, not on the page.**
            //
            // As an overlay over the whole page it had two problems: the catcher below it
            // covered the scroll area, so the page could not scroll while the panel was
            // open, and the panel stayed fixed in the window while the episode it belongs
            // to scrolled away.
            //
            // In the content both go away: the wheel reaches the scroll area because the
            // catcher is inside it.
            //
            // **There is no named coordinate space "serienseite" anymore.** It only carried
            // the bottom edge of each episode row so the panel could open under the clicked
            // download ring. The ring is gone, so the space is unused.
            //
            // **Left, not right: the panel opens under its button.** The button sits in the
            // row below the play button, so on the left. A panel opening at the other end
            // of the window leaves the user searching for what it refers to.
            //
            // `heroHeightValue + 8` is the bottom of the button row plus the same 8 pt gap the
            // movie page's download panel has. It is tied to the page measurement and not
            // to the button itself: the row shifts with the label length ("Fortsetzen" is
            // longer than "Abspielen"), and a panel whose position changes from title to
            // title would be more restless than one that always starts on the same line.
            .overlay(alignment: .topLeading) {
                if selectionOpen {
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.001)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(Theme.leap) { selectionOpen = false }
                            }
                        MacLoadSelection(model: model, series: series, seasons: seasons,
                                       preloaded: selected.map { [$0.id: episodes] } ?? [:],
                                       opened: $selectionOpen,
                                       proceed: { selectedEpisodes, quality in
                                           selectionLoad(selectedEpisodes, quality)
                                       })
                            .padding(.leading, Theme.edgeSpacing)
                            .padding(.top, Theme.heroHeightValue + 8)
                    }
                    .transition(.opacity)
                    .zIndex(40)
                }
            }
            .overlay(alignment: .topLeading) {
                if seasonPanelOpen, !loadItem.isEmpty {
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.001)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(Theme.leap) { seasonPanelOpen = false }
                            }
                        LoadPanel(model: model, entries: loadItem,
                                  title: loadTitle,
                                  images: loadImages,
                                  opened: $seasonPanelOpen)
                            // Under the button that opened it. The download selection is the only way here,
                            // so there is only one place.
                            .padding(.leading, Theme.edgeSpacing)
                            .padding(.top, Theme.heroHeightValue + 8)
                    }
                    .transition(.opacity)
                }
            }
        }
        .scrollIndicators(.never)
        // **The milky bar at the top edge.** macOS 26 puts it over every scroll view on
        // its own. It was never in our code. Over the image it blended in; on plain
        // background on the left it showed as a band.
        //
        // What the framework adds unasked has to be turned off just like what we write
        // ourselves. This is the same window setting as the movie page. Without it, the
        // window preference would flip back and forth when switching between the two
        // pages, and AppKit recomputes layout on every flip.
        .toolbar(.hidden)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .pagesScroll()
        .background(Theme.reason)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pagesWidth = $0 }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, new in
            headerState.offset = new
        }
        .overlay(alignment: .top) {
            DetailHeader(title: series.name, state: headerState, back: back)
        }
        .task { await load() }
        // Reload the episodes after the player closes: it is a layer above the page, so
        // the `.task(id:)` below does not rerun. See `AppModel.playbackEnded`.
        .onChange(of: model.pagesRefresh) { _, _ in Task { await episodesLoad() } }
        // **Only for a season change.** The first selection, with its episodes, comes
        // in one pass from `load()`.
        .task(id: selected?.id) {
            guard firstPull, let season = selected?.id, season != episodesFor else { return }
            episodesFor = season
            // **And not while no season is selected.** Without a hint, `init` selects no
            // season. When the seasons came from the cache, `seasonsPresent` was immediately
            // true and this task fetched **all** episodes of the series with `season: nil`.
            // The selection arrived shortly after, the task ran again, and the list was
            // built a second time with different content, in the middle of the push
            // transition. That is exactly what `seasonsPresent` was introduced to prevent.
            //
            // If the series has no seasons at all, `load()` fetches the episodes itself,
            // so there is nothing to do here.
            await episodesLoad()
        }
    }

    // MARK: Sections

    private var segment: some View {
        // **No gate on the section.** Holding the section back until the page has
        // settled looked like it would avoid rebuilds during the transition, but
        // measured, the series page animates as smoothly as the movie page: 107 frames
        // in 457 ms against 110 in 460, largest frame gap 26 against 14 ms.
        //
        // The gate made things worse: the page came in **empty**, with a loader instead
        // of content, and jumped to full a moment later. The movie page never had a
        // gate.
        //
        // What still matters is that switching itself must not jump. The loader fades
        // into the list, and the season pill does not appear abruptly.
        //
        // **No animation on data arrival.** Animating the change from the 200 pt loader
        // to the episode list is a height jump of about a thousand points. Over 250 ms
        // it forces the `LazyVStack` to build its rows step by step during the push,
        // each with its own image request. The iPhone version animates nothing on data
        // arrival; the list just grows.
        segmentContent
    }

    @ViewBuilder
    private var segmentContent: some View {
        switch tab {
        case .episodes:
            VStack(alignment: .leading, spacing: 0) {
                // **The picker shows as soon as there are seasons**, not only from two.
                //
                // It used to depend on `seasons.count > 1`, on the idea that a button with one
                // choice is no button. The iPhone reference differs in two places:
                // `SeriesView` shows it for `!seasons.isEmpty`, and so does the episode layer
                // in the Mac player. The chip is not only for switching, it also says **which**
                // season is showing. With a single season it would remove the only place that
                // says so, and for "Specials" it would hide that the user is in the specials.
                //
                // **The download button is not a chip next to the season picker.** It would be
                // the only way to download on this page, in a place nobody looks. On the iPhone
                // it sits in the row below the play button, between Watchlist and Watched, and
                // it opens the same `MacLadeauswahl` here. The row that held both side by side
                // is gone; the picker stands alone, as on the iPhone.
                if !seasons.isEmpty {
                    SeasonSelection(seasons: seasons, selected: $selected,
                                opened: $seasonOpen)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // 14 as on the iPhone (`episodesList`), plus the 12 of the row: 26 up to the
                        // first still image.
                        .padding(.bottom, 14)
                        // The open list sits above the episodes.
                        .zIndex(10)
                }
                if loads {
                    // Three rows in their final shape instead of a spinner.
                    VStack(spacing: 0) {
                        ForEach(0 ..< 3, id: \.self) { _ in
                            HStack(spacing: 16) {
                                LoadField().frame(width: 160, height: 90)
                                VStack(alignment: .leading, spacing: 8) {
                                    LoadField(corner: 3).frame(width: 220, height: 14)
                                    LoadField(corner: 3).frame(width: 90, height: 11)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 10)
                        }
                    }
                    .transition(.opacity)
                } else if episodesDisturbed || (seasonsDisturbed && seasons.isEmpty) {
                    DisturbHint(model: model) { Task { await episodesLoad() } }
                        .frame(height: 200)
                } else if episodes.isEmpty {
                    EmptyHint(text: "Keine Folgen")
                        .frame(height: 200)
                } else {
                    // **`VStack`, not `LazyVStack`.**
                    //
                    // A lazy list does not know the height of what it has not built. Scrolling up
                    // over twenty-two episodes makes the scroll area jump to the end instead of
                    // traveling the distance, and a fixed row height does not help because the list
                    // only learns it when it builds the row.
                    //
                    // Twenty-two rows are no cost, so the exact content is worth more than the
                    // saving. Images are decoded off the main path, and no animation moves the
                    // height jump.
                    //
                    // **To the window edge.** The section applies its horizontal margin on the
                    // outside, so the gray highlight also ended there on hover. A row in a list
                    // highlights across the **full** width, so the row itself carries the margin,
                    // see `EpisodesRow`.
                    //
                    // **Lazy only from 60 rows.** A season with 200 episodes (anime, daily shows)
                    // would otherwise build all rows and all image requests at once. The row height
                    // is fixed (`imageHeight + 24`), so the jump when scrolling up stays small where
                    // laziness pays off.
                    let rows = ForEach(episodes, id: \.id) { episode in
                        EpisodesRow(model: model, episode: episode)
                            // **Right-click: the tile menu**, as on every tile (``TileMenu``).
                            .tileMenu(episode, model: model,
                                         afterwards: { await episodesLoad() })
                        // No hairline between episodes; the iPhone separates them with space only.
                    }
                    Group {
                        if episodes.count > 60 {
                            LazyVStack(spacing: 0) { rows }
                        } else {
                            VStack(spacing: 0) { rows }
                        }
                    }
                    .transition(.opacity)
                    .padding(.horizontal, -Theme.edgeSpacing)
                }
            }

        case .cast:
            CastRail(model: model, folks: series.actors,
                            origin: series.name)

        case .extras:
            TitleRail(title: "Extras", entries: extras, model: model, play: true)

        case .similarOne:
            // Show empty hints only after loading has finished, as on the iPhone. Before
            // that, "Nichts Ähnliches gefunden" was shown while the request was still
            // running.
            if !firstPull, similar.isEmpty {
                Color.clear.frame(height: 200)
            } else if similarDisturbed, similar.isEmpty {
                DisturbHint(model: model) { Task { await similarLoad() } }
                    .frame(height: 200)
            } else if similar.isEmpty {
                EmptyHint(text: "Nichts Ähnliches gefunden")
                    .frame(height: 200)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.tileWidth,
                                                       maximum: Theme.tileWidth),
                                             spacing: Theme.tileSpacing,
                                             alignment: .topLeading)],
                          alignment: .leading, spacing: 20) {
                    ForEach(similar, id: \.id) { entryRecord in
                        Button { navigator.openIt(.title(entryRecord), in: section) } label: {
                            PosterCell(title: entryRecord.name,
                                         secondLine: entryRecord.productionYear.map { "\($0)" },
                                         image: model.imageURL(for: entryRecord, portrait: true),
                                         symbolText: "tv")
                        }
                        .buttonStyle(Theme.PressButton())
                        .tileMenu(entryRecord, model: model)
                    }
                }
            }
        }
    }

    // MARK: Download

    /// **One pass, not five**, as on the iPhone (`SeriesDetailView`). Seasons,
    /// selection, the episodes of the selected season and "Ähnliches" arrive
    /// together and land on the page in the same transaction. Previously the seasons
    /// appeared first, `.task(id:)` then fetched the episodes, and "Ähnliches" loaded
    /// only when the tab was opened, so "Nichts Ähnliches gefunden" showed until
    /// then.
    ///
    /// **No animation.** The Mac page animates nothing on data arrival; see
    /// `abschnitt`. The placeholder is there from the first frame and the list
    /// replaces it in one step.
    private func load() async {
        // **Side by side because they do not depend on each other.** The list needs the
        // seasons, the selection needs the current position, and only when no hint was
        // passed. In sequence the timeouts would add up; same reasoning as the episode
        // switch in the player.
        async let state: Item? = (selected == nil && withoutHint) ? await model.stateInSeries(series) : nil
        async let list = model.seasons(series)
        async let alike = model.similar(series)
        async let extra = model.extras(series)
        let fetched = await list
        // On failure the seasons from the cache stay and nothing is recorded. The
        // section reports it when none are shown.
        let seasonsNow = fetched ?? seasons
        // **Also when the seasons are already there from the cache.** The selection may
        // be open: without a hint, `init` makes none. A selection that was made stays.
        let choice: Item?
        if let already = selected { choice = already } else { choice = choose(from: seasonsNow, state: await state) }
        // Without seasons, all episodes of the series belong in the list; with seasons
        // but no selection there is nothing to fetch.
        let fetch = choice != nil || (fetched?.isEmpty ?? false)
        let newEpisodes = fetch ? await model.episodes(series: series.id, season: choice?.id) : nil
        let newSimilar = await alike
        let newExtras = await extra
        // Seasons, episode list and Similar rebuild half the page, so apply them only
        // once the page has settled (`InTravel`).
        await InTravel.waitFor()
        guard !Task.isCancelled else { return }

        seasonsDisturbed = fetched == nil
        if let fetched { seasons = fetched }
        similarDisturbed = newSimilar == nil
        if let newSimilar { similar = newSimilar }
        if let newExtras { extras = newExtras }
        if extras.isEmpty && tab == .extras { tab = .episodes }
        // If the user selected a season in the meantime, the list belongs to that
        // selection, not to this response; `.task(id:)` fetches it.
        if selected == nil || selected?.id == choice?.id {
            selected = choice
            episodesFor = choice?.id
            if fetch { episodesAccept(newEpisodes) } else { loads = false }
        }
        firstPull = true
        if let fetched { SeriesCache.shared.remember(series.id) { $0.seasons = fetched } }
    }

    /// Which season is shown. The chain is the same as in the shared version.
    ///
    /// First the hint the user arrived with: id, then **number**. The number is not
    /// redundant: the server does not always return a `SeasonId` for an episode, and
    /// then the id comparison finds nothing.
    ///
    /// If no hint came (from the library, from search), the **current** season
    /// applies, not season 1. That requires asking where the user is in the series,
    /// so that state is only fetched in this case.
    private var withoutHint: Bool {
        SeasonSelectionRule.needsState(hintID: startSeasonID, hintNumber: startSeasonNumber)
    }

    /// The computation itself lives in the package (`SeasonSelectionRule`), shared with
    /// all platforms.
    private func choose(from list: [Item], state: Item?) -> Item? {
        SeasonSelectionRule.choose(from: list, hintID: startSeasonID,
                                hintNumber: startSeasonNumber, state: state)
    }

    private func similarLoad() async {
        let fetched = await model.similar(series)
        similarDisturbed = fetched == nil
        if let fetched { similar = fetched }
    }

    private func episodesLoad() async {
        // If something from the cache is already shown, do not reset to empty;
        // otherwise the loader flashes anyway.
        loads = episodes.isEmpty
        let season = selected?.id
        let fetched = await model.episodes(series: series.id, season: season)
        // A different season was selected meanwhile: its request applies.
        await InTravel.waitFor()
        guard !Task.isCancelled else { return }
        guard selected?.id == season else { return }
        episodesAccept(fetched)
    }

    private func episodesAccept(_ fetched: [Item]?) {
        loads = false
        episodesDisturbed = fetched == nil
        guard let newOne = fetched else { return }
        episodes = newOne
        if let season = selected?.id {
            SeriesCache.shared.remember(series.id) { $0.episodes[season] = newOne }
        }
    }
}

// MARK: - Tabs

/// Episodes, Cast, Similar. The active tab is semibold with a 2 pt accent line
/// below it; the hairline runs across the full width. Same values as on the
/// iPhone.
struct TabRail: View {
    @Binding var pick: SeriesView.PageTab
    let cases: [SeriesView.PageTab]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 26) {
                ForEach(cases, id: \.self) { fall in
                    TabButton(label: fall.label,
                                active: pick == fall) { pick = fall }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.edgeSpacing)

            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }
}

struct TabButton: View {
    let label: LocalizedStringKey
    let active: Bool
    let pick: () -> Void

    @State private var hovers = false

    var body: some View {
        Button(action: pick) {
            // **One weight, and the line in white.** Semibold is wider than regular, and in
            // a horizontal row that shifts every neighbor to its right. Accent carries
            // state, never rank; "this tab is selected" is rank.
            Text(label)
                .font(Theme.listTitle)
                .foregroundStyle(active ? Theme.font
                                 : (hovers ? Theme.font : Theme.fontQuiet))
                // 11 as in `Reiter` on the iPhone. Previously 8 as stack spacing.
                .padding(.bottom, 11)
                // **The line is an overlay, not a sibling below.**
                //
                // As the second child of a `VStack`, a `Rectangle` takes any width it is
                // offered. That made each tab button as wide as the space offered, and three of
                // them in a row split the window between them. In full screen "Folgen",
                // "Besetzung" and "Ähnliches" ended up spread over 1400 pt, and the line under
                // the open tab was a third of the window wide. The trailing `Spacer` got
                // nothing.
                //
                // As an overlay the line adds no width: the button is as wide as its word. This
                // is how `Reiter` in `Sources/Shared/Style.swift` does it, with
                // `.overlay(alignment: .bottom)`.
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(active ? Theme.font : .clear)
                        .frame(height: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .onHover { hovers = $0 }
        .animation(Theme.toggle, value: active)
        .animation(Theme.timeFloat, value: hovers)
        // Which tab is open depended only on the line and the tone; for VoiceOver all
        // tabs were the same.
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Season picker

/// The season pill. Opens the list **in place**, no `Menu`, no sheet. A `Menu`
/// would be the obvious choice and is wrong for that reason: it brings system
/// metrics, system corners and a system material.
struct SeasonSelection: View {
    let seasons: [Item]
    @Binding var selected: Item?
    @Binding var opened: Bool
    /// In the player the list lies over the episodes and must not run past the window: it
    /// scrolls once it is taller than the room left. On the series page the page scrolls.
    var limited = false
    @Environment(\.onImageTint) private var onImage
    @Environment(\.imageColorSource) private var imageTint
    /// How far down the list may reach before it scrolls. `nil` until measured.
    @State private var room: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Chip(label: selected?.name ?? String(localized: "Staffel"),
                 symbol: opened ? "chevron.up" : "chevron.down",
                 active: false) {
                withAnimation(Theme.leap) { opened.toggle() }
            }

            if opened {
                let rows = VStack(spacing: 0) {
                    ForEach(seasons, id: \.id) { season in
                        SeasonRow(season: season,
                                     selected: season.id == selected?.id) {
                            selected = season
                            withAnimation(Theme.leap) { opened = false }
                        }
                        .id(season.id)
                    }
                }
                if limited {
                    // Short lists are laid out as before; only a taller one scrolls, and it
                    // opens on the selected season.
                    ViewThatFits(in: .vertical) {
                        rows
                        ScrollViewReader { reader in
                            ScrollView(showsIndicators: false) { rows }
                                .onAppear {
                                    if let id = selected?.id { reader.scrollTo(id, anchor: .center) }
                                }
                        }
                    }
                    .frame(maxHeight: room)
                    .padding(.vertical, 4)
                    .frame(width: 220, alignment: .leading)
                    .background(listBackground)
                    .padding(.top, 8)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { top in
                        // Window height from the content view; 24 stays free at the bottom.
                        let bottom = NSApp.keyWindow?.contentView?.bounds.height ?? 0
                        room = max(0, bottom - top - 24 - 8 - 8)
                    }
                    .transition(.expand(from: .topLeading))
                } else {
                    rows
                        .padding(.vertical, 4)
                        .frame(width: 220, alignment: .leading)
                        .background(listBackground)
                        .padding(.top, 8)
                        .transition(.expand(from: .topLeading))
                }
            }
        }
        // A click outside and Escape close it, as with the other panels.
        .background {
            if opened {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .frame(width: 4000, height: 4000)
                    .onTapGesture { withAnimation(Theme.leap) { opened = false } }
            }
        }
        .panelEscape(opened) { withAnimation(Theme.leap) { opened = false } }
    }

    @ViewBuilder private var listBackground: some View {
        let form = RoundedRectangle(cornerRadius: Theme.cornerArea,
                                    style: .continuous)
        form.fill(Theme.raised)
            .overlay {
                // **Over `ImageColor` in the page tone** (like the season list on the iPhone):
                // opaque because episodes sit below, but in the color the page has at this
                // point, with the white of the other surfaces over it. A fixed gray looked like
                // a foreign element.
                if onImage, let imageTint {
                    ZStack {
                        Theme.reason
                        MoodLoader(url: imageTint) { tones in
                            ImageTone.color(tones, at: SIMD2<Float>(0.2, 0.55))
                        }
                        Theme.surfaceTranslucent
                    }
                    .clipShape(form)
                }
            }
            .overlay { form.strokeBorder(Theme.margin, lineWidth: 1) }
    }
}

struct SeasonRow: View {
    let season: Item
    let selected: Bool
    let pick: () -> Void

    @State private var hovers = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 8) {
                // **Selected means white, not accent.**
                Text(verbatim: season.name)
                    .font(Theme.body)
                    .foregroundStyle(selected ? Theme.font : Theme.fontQuiet)
                    // The season name comes from the server: "Specials — Die Weihnachtsfolgen"
                    // would otherwise overflow the 220 pt wide panel.
                    .lineLimit(1)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(Theme.listTitle)
                        .foregroundStyle(Theme.font)
                        .frame(width: 14)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: Theme.rowHeight)
            .background(hovers ? Theme.hoverArea : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressRow())
        .onHover { hovers = $0 }
        .animation(Theme.timeFloat, value: hovers)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Episode row

/// One episode.
///
/// On the iPhone, watchlist, watched and play sit under one swipe gesture. A
/// pointer cannot swipe, so the same actions appear on hover. The reason is the
/// input method, not taste.
struct EpisodesRow: View {
    let model: AppModel
    let episode: Item
    /// **What a click on the row does, if set, instead of `PlayControls.starte`.**
    ///
    /// On the series page a click opens the player anew (`controls.starte` sets
    /// `PlayControls.wish`, and the player reads its start only on first
    /// launch). Inside an already running player (the episode layer) the switch must
    /// happen **in the same player**, via `toNextEpisode`. Otherwise the player
    /// would stay on `wish` unchanged, because `PlayerScreen` reads its `@State`
    /// values from `wish` only when it is first created.
    var action: ((Item) -> Void)?

    @State private var hovers = false
    /// Overwritten by the episode's state once the task below has run; until then
    /// `episode.isWatched` applies in the first frame (otherwise checkmark and bar
    /// would be wrong).
    @State private var watchedRemember: Bool?
    private var watched: Bool { watchedRemember ?? episode.isWatched }
    @Environment(PlayControls.self) private var controls

    /// 16 : 9, the same ratio as the 116 × 65 of the iPhone.
    private let imageWidth: CGFloat = 160
    private let imageHeight: CGFloat = 90

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            // **A button, not `onTapGesture`.**
            //
            // A tap gesture on an `HStack` cannot be used with VoiceOver or keyboard-only
            // navigation, so no episode could be started that way. The button wraps **only**
            // image and text; the right column stays outside, because a button inside a
            // button swallows the click (see `TileWrapper`).
            Button { if let action { action(episode) } else { controls.launch(episode) } } label: {
            HStack(alignment: .top, spacing: 18) {
            ZStack {
                // **The episode's own image, not the series'.**
                //
                // `landscapeImageURL` deliberately uses `item.seriesId ?? item.id`. That is right for
                // the tiles under "Weiterschauen", where the series image is wanted. In an
                // episode list it returns the **same** image for every row. The iPhone version
                // uses `imageURL(for: episode, maxHeight: 220)`, the episode's own thumbnail.
                //
                // **The thumbnail carries the watch state.** It already shows the progress bar,
                // which says how far along the user is; the checkmark is its end. That puts the
                // watch state in one place instead of two, and the right column belongs to the
                // download.
                ImageArea(image: model.imageURL(for: episode, maxHeight: 220),
                            width: imageWidth, height: imageHeight,
                            // A full bar **and** a checkmark would be the same information twice.
                            progress: watched ? nil : progress,
                            symbolText: "tv")
                    .watchedCheckmark(watched, border: 20, spacing: 6)
                    // **Under the pointer the still image grows; the row does not light up**, like
                    // every tile (`scale 1.04`, `zeitSchweben`). A full bright strip across the
                    // whole width was too loud for a list.
                    .scaleEffect(hovers ? 1.04 : 1)
                if hovers {
                    Circle()
                        .fill(Theme.reason.opacity(0.78))
                        .frame(width: 38, height: 38)
                        .overlay {
                            Image(systemName: "play.fill")
                                .font(Theme.listTitle)
                                .foregroundStyle(Theme.font)
                        }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    // Title of a row with an image: 15 semibold. 14 is not on any type scale.
                    Text(verbatim: headerLine)
                        .font(Theme.listTitle)
                        // Watched items recede; they do not disappear.
                        .foregroundStyle(watched ? Theme.fontQuiet : Theme.font)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    // **In progress: the remaining time instead of the runtime**, like `EpisodesRow`
                    // on the iPhone ("Noch 24 Minuten"). The bar in the image says how far; the
                    // word says how long is left.
                    if let seconds = episode.runtimeSeconds {
                        Text(verbatim: (watched ? nil : episode.remainingTimeText) ?? runtime(seconds))
                            .font(Theme.secondLine)
                            .foregroundStyle(Theme.fontVeryQuiet)
                    }
                }
                // Cleaned up; episode overviews often contain `<br>` in the raw text.
                if let text = episode.description, !text.isEmpty {
                    Text(verbatim: text)
                        .font(Theme.secondLine)
                        .foregroundStyle(Theme.fontQuiet)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            }
            .contentShape(Rectangle())
            }
            .buttonStyle(Theme.PressRow())
            .accessibilityLabel(Text(verbatim: headerLine))
            .accessibilityValue(stateText.map(Text.init) ?? Text(""))
            .accessibilityHint(Text("Abspielen"))
            .accessibilityAddTraits(watched ? [.isButton, .isSelected] : .isButton)

            // **No checkmark button at the row end.** It appeared on hover and was a second
            // way to set the watch state. The way is now the right-click menu
            // (`tileMenu`), as on every tile. The checkmark as *information* is on the
            // image.

        }
        .padding(.vertical, 12)
        // The section margin, applied inside here so the hover area reaches the window
        // edge while the content stays on the same line as everywhere else. The 6 pt
        // compensation is the row's own inner padding.
        .padding(.horizontal, Theme.edgeSpacing - 6)
        // **Fixed row height.** A `LazyVStack` builds only what is visible and
        // estimates the rest. When the estimate is wrong, the scroll area jumps on fast
        // scrolling up, and the more episodes the farther. With a fixed height there is
        // nothing to estimate. 90 for the image, 12 margin twice; title and text stay
        // below that with their line limits.
        .frame(height: imageHeight + 24)
        .contentShape(Rectangle())
        .onHover { hovers = $0 }
        .animation(Theme.timeFloat, value: hovers)
        // Bound to the state, not only to appearing: after the player closes, the same
        // episode comes back with a new state.
        .task(id: episode.isWatched) { watchedRemember = episode.isWatched }
    }

    private var headerLine: String {
        if let number = episode.indexNumber {
            return "\(number). \(episode.name)"
        }
        return episode.name
    }


    /// From `Item.watchedShare`; see the reasoning in `HomeView`.
    private var progress: Double? { episode.watchedShare }

    /// "Gesehen" is already carried by the row's trait; only the partial state needs
    /// to be written out, otherwise the bar in the image is the only information.
    /// Same rule as `TileWrapper`.
    private var stateText: String? {
        guard !watched, let progress, progress >= 0.01 else { return nil }
        return String(localized: "\(Int(progress * 100)) Prozent gesehen")
    }
}
