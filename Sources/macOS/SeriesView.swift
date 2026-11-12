import JellyfinKit
import SwiftUI
import SwiftlyCore

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
    var startSeasonNumber: Int?
    let back: () -> Void
    @Environment(Navigator.self) private var navigator
    @Environment(\.section) private var section
    @Environment(PlayControls.self) private var controls

    /// The page's data owner, the core's `SeriesVm` (`SeriesCore`); `nil` when there is no account.
    @State private var page: SeriesCore?
    @State private var tab: PageTab = .episodes
    @State private var seasonOpen = false
    @State private var seasonPanelOpen = false
    @State private var loadItem: [DownloadItem] = []
    /// What the header panel shows: "Staffel 5" or the name of an episode.
    @State private var loadTitle = ""
    /// The download selection: whole series, seasons, episodes.
    @State private var selectionOpen = false
    @State private var versionPick: VersionPick?
    /// For the header image, which is saved along with a download on the Mac.
    @Environment(\.displayScale) private var pixelMetric
    @State private var pagesWidth: CGFloat = 0
    @State private var headerState = HeaderState()

    @MainActor init(model: AppModel, series: Item,
                    startSeasonID: String? = nil, startSeasonNumber: Int? = nil,
                    back: @escaping () -> Void) {
        self.model = model
        self.series = series
        self.startSeasonID = startSeasonID
        self.startSeasonNumber = startSeasonNumber
        self.back = back
        _page = State(initialValue: SeriesCore(
            app: model, item: series, startSeasonID: startSeasonID, startSeasonNumber: startSeasonNumber))
    }

    private var current: Item { page?.item ?? series }
    private var button: SeriesButtonPart? { page?.model.button }
    private var seasonRows: [SwiftlyCore.SeasonRow] { page?.model.seasons.seasons ?? [] }
    private var selectedSeasonID: String? { page?.model.seasons.selected }
    private var more: MorePart? { page?.model.more }
    private var extras: [Item] { (more?.extras ?? []).map(Item.init(rust:)) }
    private var similar: [Item] { (more?.similar ?? []).map(Item.init(rust:)) }

    /// The seasons as `Item`s for the picker and the download selection.
    private var seasons: [Item] {
        seasonRows.map { page?.item($0.id) ?? Item(id: $0.id, name: $0.name, type: "Season") }
    }
    private var selected: Item? { seasons.first { $0.id == selectedSeasonID } }
    private var seasonBinding: Binding<Item?> {
        Binding(get: { selected },
                set: { if let id = $0?.id { page?.model.selectSeason(id) } })
    }
    private var episodes: [Item] {
        let items = page?.episodeItems() ?? [:]
        return (page?.model.episodes.rows ?? []).compactMap { items[$0.id] }
    }

    // MARK: Downloads

    /// A `DownloadItem` for an episode. **The same source the player would use**, since it is the same file.
    private func entries(_ episode: Item) -> DownloadItem? {
        guard let account = model.session?.storageAccount else { return nil }
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
        if let poster = model.imageURL(for: series, maxHeight: 600, portrait: true) {
            card[series.id] = poster
        }
        // Header image at screen resolution, for the series page in Downloads.
        if let header = model.headerImageURL(for: series, width: DownloadSeriesOverviewPage.headerPixel(
            pagesWidth: pagesWidth, pixelMetric: pixelMetric)) {
            card[DownloadManager.headerKey(series.id)] = header
        }
        // Every selected episode, not only those of the open season: the selection can take whole series.
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

    /// The selection result goes to the download panel (free space, Wi-Fi and the normal case).
    private func selectionLoad(_ selectedEpisodes: [Item], _ quality: DownloadQuality,
                               _ audio: DownloadAudioChoice) {
        loadItem = selectedEpisodes.compactMap { episode in
            entries(episode)?.inQuality(quality)
                .withAudio(audio, streams: episode.mediaSources?.first?.mediaStreams ?? [])
        }
        guard !loadItem.isEmpty else { return }
        loadTitle = series.name
        withAnimation(Theme.leap) { seasonPanelOpen = true }
    }

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
                DetailHero(model: model, title: current, state: headerState,
                           // The download button sits in the row below the play button, as on the iPhone;
                           // the selection stays here because it needs the seasons and their episodes.
                           loadSelection: {
                               withAnimation(Theme.leap) { selectionOpen.toggle() }
                           },
                           selectionOpen: selectionOpen,
                           seriesPage: page)
                    // The header draws above what comes after it (the More menu over the tabs).
                    .zIndex(1)

                WatchersRow(model: model, item: series,
                            fromCore: (more?.watchers ?? []).map(Watcher.init(core:)))
                    .padding(.horizontal, DetailPageMetric.left)
                    .padding(.top, 34)

                TabRail(pick: $tab, cases: extras.isEmpty ? [.episodes, .cast, .similarOne]
                                                                    : SeriesView.PageTab.allCases,
                        // The season choice lives in the first tab; a click on the open first tab opens the list.
                        firstLabel: seasons.isEmpty ? nil
                            : (selected?.name ?? String(localized: "Staffel")),
                        firstChevron: seasons.count > 1,
                        chevronOpen: seasonOpen,
                        onReselect: {
                            if seasons.count > 1 { withAnimation(Theme.leap) { seasonOpen.toggle() } }
                        })
                    .padding(.top, 34)

                segmentContent
                    .padding(.horizontal, DetailPageMetric.left)
                    .padding(.top, 14)
            }
            .padding(.bottom, 40)
            // The color of the header image under the page; it scrolls with the header.
            .background(alignment: .top) {
                StretchedMood(url: model.headerImageURL(for: series), state: headerState)
            }
            .environment(\.onImageTint, true)
            .environment(\.imageColorSource, model.headerImageURL(for: series))
            // The download panels live in the content, so the page keeps scrolling while they are open and
            // they scroll along with the button they belong to. They open under that button, on the left.
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
                                       proceed: { selectedEpisodes, quality, audio in
                                           selectionLoad(selectedEpisodes, quality, audio)
                                       })
                            .padding(.leading, DetailPageMetric.left)
                            .padding(.top, DetailPageMetric.railBottom + 8)
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
                            .padding(.leading, DetailPageMetric.left)
                            .padding(.top, DetailPageMetric.railBottom + 8)
                    }
                    .transition(.opacity)
                }
            }
        }
        .scrollIndicators(.never)
        // The window setting must match the movie page's; see there.
        .toolbar(.hidden)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .pagesScroll()
        .background(Theme.reason)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pagesWidth = $0 }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, new in
            headerState.offset = new
        }
        .overlay(alignment: .top) {
            DetailHeader(title: series.name, state: headerState, back: back,
                         mood: model.headerImageURL(for: series))
        }
        // The core loads seasons, the open season's episodes, cast, extras, similar and watchers, and keeps the
        // page current. Cancelled (page covered) is not a failure; the task restarts on return.
        .task {
            if page == nil {
                page = SeriesCore(app: model, item: series, startSeasonID: startSeasonID,
                                  startSeasonNumber: startSeasonNumber)
            }
            await page?.run(app: model)
        }
        // After the player closes the page refreshes (it is a layer above, so `.task` does not rerun).
        .onChange(of: model.pagesRefresh) { _, _ in page?.model.refresh() }
        .onChange(of: model.watchersShown) { _, _ in page?.send(options: model) }
        .onChange(of: model.downloadButtonShow) { _, _ in page?.send(options: model) }
        .onChange(of: PlayOutputs.shared.targets.map(\.id)) { _, _ in page?.send(options: model) }
        .onChange(of: extras.isEmpty) { _, none in if none && tab == .extras { tab = .episodes } }
        .versionPick($versionPick) { choice, version in
            guard let page else { return }
            page.launch(page.episodeAction(choice.itemId, pick: version.id), since: choice.since,
                        controls: controls) { versionPick = $0 }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var segmentContent: some View {
        switch tab {
        case .episodes:
            VStack(alignment: .leading, spacing: 0) {
                // The picker shows as soon as there are seasons: it also says WHICH season is showing.
                if !seasons.isEmpty {
                    SeasonSelection(seasons: seasons, selected: seasonBinding,
                                opened: $seasonOpen, showsPill: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 14)
                        // The open list sits above the episodes.
                        .zIndex(10)
                }
                episodesList
            }

        case .cast:
            let folks = (more?.cast ?? []).map(Person.init(core:))
            if folks.isEmpty {
                if more?.similarLoads == true {
                    Color.clear.frame(height: 200)
                } else {
                    EmptyHint(text: "Keine Besetzung hinterlegt.")
                        .frame(height: 200)
                }
            } else {
                CastRail(model: model, folks: folks, origin: series.name)
            }

        case .extras:
            TitleRail(title: "Extras", entries: extras, model: model, play: true, looks: looks)

        case .similarOne:
            if similar.isEmpty, more?.similarLoads == true {
                Color.clear.frame(height: 200)
            } else if similar.isEmpty, more?.similarFailed == true {
                DisturbHint(model: model) { page?.model.refresh() }
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
                        let look = looks[entryRecord.id]
                        Button { navigator.openIt(.title(entryRecord), in: section) } label: {
                            PosterCell(title: look?.title ?? entryRecord.name,
                                         secondLine: look != nil ? look?.subtitle : entryRecord.productionYear.map { "\($0)" },
                                         image: look?.image ?? model.imageURL(for: entryRecord, portrait: true),
                                         symbolText: "tv")
                        }
                        .buttonStyle(Theme.PressButton())
                        .tileMenu(entryRecord, model: model)
                    }
                }
            }
        }
    }

    /// The tiles under the page take their pictures and wording from the core, found by id.
    private var looks: [String: RustTileLook] {
        var out: [String: RustTileLook] = [:]
        for tile in (more?.similar ?? []) + (more?.extras ?? []) { out[tile.id] = RustTileLook(tile) }
        return out
    }

    @ViewBuilder
    private var episodesList: some View {
        let part = page?.model.episodes
        if page?.model.seasons.disturbed == true && seasonRows.isEmpty {
            DisturbHint(model: model) { page?.model.load() }
                .frame(height: 200)
        } else {
            switch part?.status {
            case .disturbed:
                DisturbHint(model: model) { page?.model.retryEpisodes() }
                    .frame(height: 200)
            case .empty:
                EmptyHint(text: seasonRows.isEmpty ? "Keine Folgen" : "Keine Folgen in dieser Staffel")
                    .frame(height: 200)
            case .ready:
                episodeRows(part?.rows ?? [], more: part?.moreAvailable ?? false)
            default:
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
            }
        }
    }

    private func episodeRows(_ rows: [SwiftlyCore.EpisodeRow], more: Bool) -> some View {
        let items = page?.episodeItems() ?? [:]
        // A `VStack` up to 60 rows: a lazy list does not know the height it has not built, and scrolling up
        // would jump. Lazy only for very long seasons.
        let list = ForEach(rows, id: \.id) { row in
            let episode = items[row.id] ?? Item(id: row.id, name: row.title, type: "Episode")
            EpisodesRow(model: model, episode: episode,
                        action: { _ in startEpisode(row.id) },
                        download: { withAnimation(Theme.leap) { selectionOpen.toggle() } },
                        look: RustEpisodeLook(row: row))
                // Right-click: the tile menu, as on every tile.
                .tileMenu(episode, model: model, afterwards: { page?.model.refresh() })
        }
        return VStack(alignment: .leading, spacing: 0) {
            Group {
                if rows.count > 60 {
                    LazyVStack(spacing: 6) { list }
                } else {
                    VStack(spacing: 6) { list }
                }
            }
            // The image lines up with the page edge; only the hover fill reaches past it.
            .padding(.leading, -10)
            if more {
                Button {
                    withAnimation(Theme.leap) { page?.model.moreEpisodes() }
                } label: {
                    Text("Mehr Folgen")
                        .font(.app(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.vertical, 12)
                }
                .buttonStyle(Theme.PressButton())
            }
        }
        .transition(.opacity)
    }

    private func startEpisode(_ id: String) {
        guard let page else { return }
        page.launch(page.episodeAction(id, pick: nil), since: nil, controls: controls) { versionPick = $0 }
    }
}

extension SeriesCore {
    /// What a pick of a version does: the main button's episode goes through `playNext` so that it also works
    /// when it lies in another season than the open one. Without a pick this is the plain press.
    func episodeAction(_ id: String?, pick: String?) -> PlayAction? {
        guard let id, id != model.button.nextEpisode else { return model.playNext(pick: pick) }
        return model.playEpisode(id, pick: pick)
    }

    /// What a press on Play (or a menu entry that plays) does, as the core decides it. `since` overrides the
    /// core's start second; `choose` shows the version list.
    func launch(_ action: PlayAction?, since: Double? = nil, controls: PlayControls,
                choose: (VersionPick) -> Void) {
        guard let action else { return }
        switch action {
        case .wait:
            return
        case .choose(let id, let at, let versions):
            choose(VersionPick(heading: String(localized: "Fassung wählen"), options: versions,
                               since: since ?? at, itemId: id))
        case .resolve(let id, let at):
            // The list entry has no `MediaSources`: the player fetches and asks itself.
            guard let episode = item(id) else { return }
            controls.launch(episode, since: since ?? at)
        case .start(let id, let at, let source):
            guard let episode = item(id) else { return }
            controls.launch(episode, since: since ?? at, sourceID: source)
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
    /// The first tab shows this (the selected season) instead of its own name.
    var firstLabel: String? = nil
    var firstChevron = false
    var chevronOpen = false
    /// A click on the tab that is already open.
    var onReselect: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 28) {
                ForEach(cases, id: \.self) { fall in
                    let isFirst = fall == cases.first
                    TabButton(label: fall.label,
                                active: pick == fall,
                                verbatim: isFirst ? firstLabel : nil,
                                chevron: isFirst && firstChevron,
                                chevronOpen: chevronOpen) {
                        if pick == fall { if isFirst { onReselect?() } } else { pick = fall }
                    }
                }
                Spacer(minLength: 0)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
        }
        // 820 wide from the 36 margin, like the episode list under it.
        .frame(maxWidth: 820, alignment: .leading)
        .padding(.leading, DetailPageMetric.left)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TabButton: View {
    let label: LocalizedStringKey
    let active: Bool
    /// Replaces `label` (a season name from the server is not translated).
    var verbatim: String? = nil
    var chevron = false
    var chevronOpen = false
    let pick: () -> Void

    @State private var hovers = false

    var body: some View {
        Button(action: pick) {
            // **One weight, and the line in white.** Semibold is wider than regular, and in
            // a horizontal row that shifts every neighbor to its right. Accent carries
            // state, never rank; "this tab is selected" is rank.
            HStack(spacing: 5) {
                if let verbatim { Text(verbatim: verbatim) } else { Text(label) }
                if chevron {
                    Image(icon: chevronOpen ? "chevron.up" : "chevron.down", size: 11)
                        .font(.app(size: 11, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
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
/// The season button of the design: 34 high, radius 8, surface fill, name 15/600 and a caret.
fileprivate struct SeasonPill: View {
    let label: String
    let opened: Bool
    let pick: () -> Void
    @State private var hovers = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 6) {
                Text(verbatim: label).font(.app(size: 15, weight: .semibold))
                Image(icon: opened ? "chevron.up" : "chevron.down", size: 11)
                    .font(.app(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Theme.font)
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(hovers ? Theme.raised : Theme.area,
                        in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .onHover { hovers = $0 }
    }
}

struct SeasonSelection: View {
    let seasons: [Item]
    @Binding var selected: Item?
    @Binding var opened: Bool
    /// In the player the list lies over the episodes and must not run past the window: it
    /// scrolls once it is taller than the room left. On the series page the page scrolls.
    var limited = false
    /// `false` when the open first tab of the series page is the button (no pill of its own).
    var showsPill = true
    @Environment(\.onImageTint) private var onImage
    @Environment(\.imageColorSource) private var imageTint
    /// How far down the list may reach before it scrolls. `nil` until measured.
    @State private var room: CGFloat?
    /// Measured height of the season rows.
    @State private var rowsHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsPill {
                SeasonPill(label: selected?.name ?? String(localized: "Staffel"), opened: opened) {
                    withAnimation(Theme.leap) { opened.toggle() }
                }
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
                    // **Height is explicit**: the measured height of the rows, capped at the room
                    // left (and 360). A `ScrollView` takes all the height it is offered, and
                    // `ViewThatFits` + `frame(maxHeight:)` let it do so; now it gets exactly what
                    // the entries need until the cap, then it scrolls.
                    let cap = min(room ?? 360, 360)
                    ScrollViewReader { reader in
                        ScrollView(showsIndicators: false) {
                            rows.onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                                rowsHeight = $0
                            }
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(height: min(rowsHeight > 0 ? rowsHeight : CGFloat(seasons.count) * 38, cap))
                        .onAppear {
                            if let id = selected?.id { reader.scrollTo(id, anchor: .center) }
                        }
                    }
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
                    Image(icon: "checkmark")
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
    /// Opens the page's download choice. Without it (the player) the hover shows no download.
    var download: (() -> Void)?
    /// The core's wording of this row (`AppModel.coreServes`); `nil` shows the Swift one.
    var look: RustEpisodeLook?

    @State private var hovers = false
    /// Overwritten by the episode's state once the task below has run; until then
    /// `episode.isWatched` applies in the first frame (otherwise checkmark and bar
    /// would be wrong).
    @State private var watchedRemember: Bool?
    private var watched: Bool { watchedRemember ?? episode.isWatched }
    @Environment(PlayControls.self) private var controls

    /// 16 : 9, the same ratio as the 116 x 65 of the iPhone.
    private let imageWidth: CGFloat = 160
    private let imageHeight: CGFloat = 90

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // **A button, not `onTapGesture`.**
            //
            // A tap gesture on an `HStack` cannot be used with VoiceOver or keyboard-only
            // navigation, so no episode could be started that way. The button wraps **only**
            // image and text; the hover icons stay outside, because a button inside a
            // button swallows the click (see `TileWrapper`).
            Button { if let action { action(episode) } else { controls.launch(episode) } } label: {
                HStack(alignment: .top, spacing: 16) {
                    // **The episode's own image, not the series'.** `landscapeImageURL` uses
                    // `item.seriesId ?? item.id`, which would give every row the same image.
                    //
                    // **The thumbnail carries the watch state**: its flush bottom bar is full for
                    // a watched episode, so the inline check next to the title is the only mark.
                    ImageArea(image: look?.image ?? model.imageURL(for: episode, maxHeight: 220),
                                width: imageWidth, height: imageHeight,
                                progress: watched ? 1 : progress,
                                symbolText: "tv")

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(verbatim: headerLine)
                                .font(Theme.listTitle)
                                .foregroundStyle(Theme.font)
                                .lineLimit(2)
                            // **In progress: the remaining time instead of the runtime.**
                            if let look, !look.secondaryLine.isEmpty {
                                Text(verbatim: look.secondaryLine)
                                    .font(.app(size: 12))
                                    .foregroundStyle(Theme.fontVeryQuiet)
                                    .lineLimit(1)
                            } else if look == nil, let seconds = episode.runtimeSeconds {
                                Text(verbatim: (watched ? nil : episode.remainingTimeText) ?? runtime(seconds))
                                    .font(.app(size: 12))
                                    .foregroundStyle(Theme.fontVeryQuiet)
                                    .lineLimit(1)
                            }
                            if watched {
                                Image(icon: "checkmark.circle.fill", size: 14)
                                    .foregroundStyle(Theme.fontVeryQuiet)
                                    .accessibilityHidden(true)
                            }
                        }
                        // Cleaned up; episode overviews often contain `<br>` in the raw text.
                        if let text = episode.description, !text.isEmpty {
                            Text(verbatim: text)
                                .font(.app(size: 13))
                                .foregroundStyle(Theme.fontQuiet)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(Theme.PressRow())
            .accessibilityLabel(Text(verbatim: headerLine))
            .accessibilityValue(stateText.map(Text.init) ?? Text(""))
            .accessibilityHint(Text("Abspielen"))
            .accessibilityAddTraits(watched ? [.isButton, .isSelected] : .isButton)

            // **Download and More appear under the pointer** (a pointer cannot swipe). Always in
            // the layout, only faded, so the text does not reflow on hover.
            HStack(spacing: 14) {
                if let download {
                    Button(action: download) {
                        Image(icon: "arrow.down.circle", size: 18).font(.app(size: 18))
                    }
                    .buttonStyle(Theme.PressButton())
                    .help(Text("Laden"))
                    .accessibilityLabel(Text("Laden"))
                }
                Menu {
                    Button("Abspielen") {
                        if let action { action(episode) } else { controls.launch(episode) }
                    }
                    Button(watched ? "Als ungesehen markieren" : "Als gesehen markieren") {
                        let target = !watched
                        watchedRemember = target
                        Task {
                            if await model.setWatched(episode, an: target) != nil { watchedRemember = !target }
                        }
                    }
                } label: {
                    Image(icon: "ellipsis", size: 18).font(.app(size: 18))
                }
                .menuStyle(.button)
                .buttonStyle(Theme.PressButton())
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Text("Mehr"))
            }
            .foregroundStyle(Theme.fontQuiet)
            .padding(.leading, 12)
            .padding(.top, 2)
            .opacity(hovers ? 1 : 0)
            .allowsHitTesting(hovers)
        }
        .padding(10)
        // **Fixed row height.** A `LazyVStack` builds only what is visible and estimates the
        // rest; with a fixed height there is nothing to estimate. 90 for the image, 10 margin
        // twice; title and text stay below that with their line limits.
        .frame(height: imageHeight + 20)
        .frame(maxWidth: 820)
        .background(hovers ? Theme.groupsArea : .clear,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovers = $0 }
        .animation(Theme.timeFloat, value: hovers)
        // Bound to the state, not only to appearing: after the player closes, the same
        // episode comes back with a new state.
        .task(id: episode.isWatched) { watchedRemember = episode.isWatched }
    }

    private var headerLine: String {
        if let look { return look.title }
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
