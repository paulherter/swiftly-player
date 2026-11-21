import JellyfinKit
import OSLog
import SwiftUI

import SwiftlyCore

/// The series page.
///
/// Its core is the one big button: it knows where you are. The episode in progress, or the next unwatched one if
/// none is open, comes from the Rust core (`SeriesVm`, owned by `SeriesCore`); the page draws its parts (seasons,
/// episode rows, head and main button, cast, extras, similar, watchers) and sends intents back.
struct SeriesDetailView: View {
    let model: AppModel
    let series: Item
    /// The season of the episode we came from, by ID and by number (some servers return no `SeasonId`); the core
    /// picks the season from them and its own state.
    var startSeasonID: String? = nil
    var startSeasonNumber: Int? = nil

    @Environment(\.dismiss) private var back
    @Environment(\.wide) private var wide
    @Environment(\.broad) private var broad
    @Environment(\.watchlistShown) private var watchlistShown
    @Environment(\.displayScale) private var pixelMetric
    @State private var pagesWidth: CGFloat = 0

    /// How far it has scrolled; only `DetailHeaderReader` reads it, so a scroll step does not rebuild the page.
    @State private var distance = ScrollDistance()

    /// The page's data owner, the core's `SeriesVm` (`SeriesCore`); `nil` when there is no account.
    @State private var page: SeriesCore?
    @State private var loadSheet = false
    /// The count was unknown once on this page: the chevron's width stays reserved after the answer (see `PageTab`).
    @State private var seasonCountWasPending = false
    /// When the page was made: the device trace says how long after it the season chevron stood.
    @State private var openedAt = Date()
    @State private var loadItem: [DownloadItem] = []
    @State private var selectionOpen = false
    @State private var loadTitle = ""
    @State private var play: PlayRequest?
    @State private var moreOpen = false
    /// What Seerr adds to the More list (report a problem, delete from the server) and its two sheets.
    @State private var seerrMenu = SeerrTitleMenu()
    @State private var message: String?
    @State private var prepares = false
    @State private var tab = 0
    @State private var gridWidth: CGFloat = 0
    @State private var seasonListOpen = false
    /// The same series at Seerr (when connected): season state, request sheet, titles not on the server.
    @State private var seerr: SeerrTitleFlow?

    @MainActor init(model: AppModel, series: Item, startSeasonID: String? = nil, startSeasonNumber: Int? = nil) {
        self.model = model
        self.series = series
        self.startSeasonID = startSeasonID
        self.startSeasonNumber = startSeasonNumber
        _page = State(
            initialValue: SeriesCore(
                app: model, item: series, startSeasonID: startSeasonID, startSeasonNumber: startSeasonNumber))
    }

    private var current: Item { page?.item ?? series }

    /// "Extras" (tab 3) is reserved from frame 1 and drawn only when the title has some.
    private var hiddenTabs: Set<Int> {
        let none = more?.extras.isEmpty ?? true
        return none ? Set<Int>([3]) : Set<Int>()
    }

    #if DEBUG
    /// Proof hook: `-SwiftlyLiveOpenMore` opens the "Mehr" menu once the page has settled.
    private var openMoreHook: some View {
        Color.clear.frame(width: 0, height: 0).task {
            guard ProcessInfo.processInfo.arguments.contains("-SwiftlyLiveOpenMore") else { return }
            try? await Task.sleep(for: .seconds(3))
            moreOpen = true
        }
        .task {
            // Proof hook (Werkzeuge/load-sheet-ride-run.sh): `-SwiftlyLiveOpenLoad <ms>` opens the season download sheet <ms>
            // after the page appears, so a slow fixture delivers the episode counts while the sheet is already open.
            let args = ProcessInfo.processInfo.arguments
            guard let at = args.firstIndex(of: "-SwiftlyLiveOpenLoad"), at + 1 < args.count else { return }
            try? await Task.sleep(for: .milliseconds(Int(args[at + 1]) ?? 1500))
            selectionOpen = true
        }
    }
    #endif
    private var button: SeriesButtonPart? { page?.model.button }
    private var seasonList: [SeasonRow] { page?.model.seasons.seasons ?? [] }
    /// What decides when the Seerr side is (re)started: the series' TMDB id and the seasons the server has.
    private var seerrKey: String {
        let numbers = seasonList.compactMap(\.number).map(String.init).joined(separator: ",")
        return "\(page?.model.tmdbId().map(String.init) ?? "-")|\(numbers)|\(model.seerr.connected)"
    }
    /// **The season button's chevron is the core's rule** (`SeasonsPart.chevron`): the button is always a menu, so the
    /// chevron stands from frame 1 and no answer (list, count, Seerr) ever toggles it. A pending count keeps the chevron's width reserved.
    private var seasonsOffered: Bool { page?.model.seasons.chevron ?? false }
    private var seasonCountPending: Bool { page?.model.seasons.countPending ?? false }
    private var chevronTrace: String { "\(seasonsOffered)" }

    private func startSeerr() async {
        guard model.seerr.connected, let tmdb = page?.model.tmdbId() else { return }
        let numbers = seasonList.compactMap(\.number)
        if let flow = seerr, flow.tmdb == tmdb { flow.setLibrary(numbers); return }
        // A flow warmed when the tile was pressed already has (or is getting) Seerr's answer: take it over.
        if let warmed = SeerrTitleWarm.flow(tmdb: tmdb) {
            seerr = warmed
            warmed.setLibrary(numbers)
            if warmed.ready { return }
            await warmed.start(library: numbers)
            return
        }
        let flow = SeerrTitleFlow(hub: model.seerr.hub, art: "tv", tmdb: tmdb)
        seerr = flow
        await flow.start(library: numbers)
    }

    private var selectedSeason: SeasonRow? {
        let id = page?.model.seasons.selected
        return seasonList.first { $0.id == id }
    }
    private var more: MorePart? { page?.model.more }
    private var title: String {
        guard let name = button?.title, !name.isEmpty else { return series.name }
        return name
    }

    private var headerImage: URL? {
        button?.image.flatMap { URL(string: $0.address) } ?? model.headerImageURL(for: series)
    }
    private var logoImage: URL? {
        button?.logo.flatMap { URL(string: $0.address) } ?? model.logoURL(for: series)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.reason.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // The same header as on the movie page, as its own building block so it is not written twice.
                    hero
                    VStack(alignment: .leading, spacing: Theme.blockGap) {
                        // Above the button, directly under the name.
                        proofRow
                        // **Button and row are one block, so they sit closer.** The spacing was 14, as large as
                        // to everything else, but horizontally the row's fields are only 8 apart. The gap above
                        // was then larger than the gap between fields, and the row read as a separate thing
                        // instead of a continuation of the button.
                        VStack(alignment: .leading, spacing: Theme.actionGap) {
                            primaryButton
                            actionRail
                        }
                        // The row has its labels close under the circles; without extra padding they almost
                        // touch the text below.
                        .padding(.bottom, 8)
                        description
                    }
                    .readColumn(wide: wide)
                    .padding(.horizontal, Theme.margin(wide: wide))
                    .padding(.top, 4)
                    .padding(.bottom, 22)

                    PageTab(title: ["Folgen", "Besetzung", "Ähnliches", "Extras"],
                           selected: $tab,
                           firstLabel: seasonList.isEmpty ? nil
                               : (selectedSeason?.name ?? String(localized: "Staffel")),
                           firstChevron: seasonsOffered,
                           firstChevronReserved: seasonCountPending || seasonCountWasPending,
                           chevronOpen: seasonListOpen,
                           hiddenTabs: hiddenTabs,
                           onReselect: { _ in
                               if seasonsOffered { withAnimation(Theme.leap) { seasonListOpen.toggle() } }
                           })
                    .onChange(of: seasonCountPending, initial: true) { _, pending in
                        if pending { seasonCountWasPending = true }
                    }
                    .onChange(of: chevronTrace, initial: true) { _, _ in
                        let ms = Int(Date().timeIntervalSince(openedAt) * 1000)
                        AppLog.writeOut("[Staffelpfeil] chevron \(seasonsOffered ? "shown" : "hidden") "
                            + "at +\(ms) ms, source=core-always, series=\(series.id), seasons=\(seasonList.count), "
                            + "expected=\(page?.model.seasons.expected ?? 0), core=\(page != nil)")
                    }

                    switch tab {
                    case 0: episodesList.readColumn(wide: wide, inset: Theme.margin(wide: wide))
                    case 1: cast
                    case 3 where more?.extras.isEmpty == false: extrasSection
                    default: similarSection
                    }
                    // **At the foot of the page, where its late arrival moves nothing.** "Seen by" comes with the
                    // viewers' answer (after the first frame); above the season picker it pushed the picker and
                    // the episode rows down. Like on the film page it joins the page's last block.
                    WatchersRow(model: model, list: (more?.watchers ?? []).map(Watcher.init(core:)))
                        .padding(.top, 8)
                }
                // **Never wider than the screen.** If a child gets wider, the whole page does, and a page wider
                // than its scroll area can be dragged sideways.
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                // **The color of the header image beneath the page** (experiment `experiment-glas`), narrow and
                // wide. When wide, `HeroHeader` carries its image as the background and fades it via
                // `onImageTint` with a mask instead of `reason`; underneath lies the same mesh, computed from
                // its minimum height (iPad).
                .background(alignment: .top) {
                    MoodReason(url: headerImage, since: Theme.heroHeightValue)
                }
                // Translucent instead of solid surfaces on top; see `Theme.flaecheDurchsichtig`.
                .environment(\.onImageTint, true)
                .environment(\.imageColorSource, headerImage)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(.named("blatt"))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pagesWidth = $0 }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, new in
                distance.setDown(new, until: Theme.heroHeightValue + MoodReason.runOut)
            }
            .ignoresSafeArea(edges: .top)

            // The sheet hangs on an empty surface; without the `if`, wide windows would get two paths to the
            // same actions.
            ActionSheet(opened: $moreOpen, title: sheetTitle, actions: moreActions)
                .zIndex(20)
            SeerrTitleMenuSheets(menu: seerrMenu, model: model) { back() }
            // **The sheet is always in the tree, even when empty.** It used to hang on `if !loadItem.isEmpty`,
            // and on the **first** open the items and `opened` were set in the same pass: the view was created
            // at the moment it should already be open, with no closed state to slide in from.
            LoadSheet(opened: $loadSheet, model: model, entries: loadItem,
                      title: loadTitle, images: loadImages,
                      failed: { message = $0 })
                .zIndex(20)
            // **The selection sits in front of the load sheet, not beside it.** It only collects episodes;
            // space, Wi-Fi and size are still computed by `LoadSheet`.
            LoadSelection(opened: $selectionOpen, model: model, series: current,
                        seasons: seasonItems,
                        preloaded: selectedSeason.map { [$0.id: openEpisodes] } ?? [:]) { selected, quality, audio in
                let newOne = selected.compactMap { episode in
                    entries(episode)?.inQuality(quality)
                        .withAudio(audio, streams: episode.mediaSources?.first?.mediaStreams ?? [])
                }
                guard !newOne.isEmpty else { return }
                sheetShow(newOne, title: current.name)
            }
            .zIndex(20)
            if let message {
                HintStrip(text: message) { self.message = nil; page?.model.dismissMessage() }
                    .zIndex(21)
            }

            DetailHeaderReader(title: title, distance: distance, mood: headerImage) { back() }
        }
        .animation(Theme.sectionSwitch, value: tab)
        // Nothing inside the page animates in: images, the logo and the colour mood appear in place.
        .arrivesStill()
        .onChange(of: seerrMenu.message) { _, text in
            guard let text else { return }
            message = text
            seerrMenu.message = nil
        }
        // **Seasons in a sheet, not a dropdown in the page**: a list hanging in the scroll
        // area closed on every scroll, and on a short page (a season without episodes) its last entries could
        // not be reached. The sheet scrolls on its own and always shows every season.
        .overlay(alignment: .topTrailing) {
            ZStack {
                SeasonPickerSheet(opened: $seasonListOpen,
                                  library: seasonList,
                                  selectedID: selectedSeason?.id,
                                  seerr: seerr?.picker ?? [],
                                  selectLibrary: { season in
                                      withAnimation(Theme.reveal) { page?.model.selectSeason(season.id) }
                                  },
                                  request: { seerr?.open(season: $0) })
                if let seerr { RequestSheet(flow: seerr) }
            }
        }
        #if os(iOS)
        .background(SwipeBack())
        .toolbar(.hidden, for: .navigationBar)
        .playerCover(item: $play) { wish in
            PlayerScreen(model: model, item: wish.item,
                         plan: wish.plan, startAt: wish.startAt)
        }
        #endif
        // The core loads the series, its seasons, the open season's episodes, the next episode with its plan,
        // then cast, extras, similar and watchers, and keeps the page current. Cancelled (page covered) is not a
        // failure; the task restarts on return.
        .task { await page?.run(app: model) }
        .task(id: seerrKey) { await startSeerr() }
        // **Refetch after the player**, and only once the end report has gone through; see
        // `AppModel.playbackEnded`. Otherwise progress and "watched" would stay at their pre-playback state.
        .catchUp(at: model.pagesRefresh) { page?.model.refresh() }
        // What the core tells the host to do (play, open a trailer page, hand a title to another device ...).
        .onChange(of: button?.effectSeq) { _, _ in drain() }
        .onChange(of: button?.message) { _, new in if let new { message = new } }
        .onChange(of: button?.toggleError) { _, new in if let new { message = new } }
        // The tiles under the page take their wording from the core, like the home page's.
        .onChange(of: more) { _, new in if let new { rememberLooks(new) } }
        // **The season brought along can arrive late.** `SeasonTarget` refetches the episode because the list
        // entry can carry an old season: when someone finishes a season and adds the next, the tile still shows
        // the old one. That answer only arrives once the page is up; without this the refetch had no effect:
        // "Play S6E1" above, season 5 below.
        .onChange(of: startSeasonID) { _, new in
            guard let new, seasonList.contains(where: { $0.id == new }), new != selectedSeason?.id else { return }
            page?.model.selectSeason(new)
        }
        // What the core cannot know: settings, rights, devices in reach.
        .onChange(of: model.watchersShown) { _, _ in page?.send(options: model) }
        .onChange(of: model.downloadButtonShow) { _, _ in page?.send(options: model) }
        .onChange(of: PlayOutputs.shared.targets.map(\.id)) { _, _ in page?.send(options: model) }
    }

    // MARK: Parts

    private var hero: some View {
        HeroImage(url: headerImage, blur: page?.model.button.imageBlurHash,
                  stand: page?.model.button.tileImages.compactMap { URL(string: $0.address) } ?? [])
            .overlay(alignment: .bottom) { HeroRunOut(image: headerImage) }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    #if os(iOS)
                    TitleMark(title: title, logo: logoImage)
                    #else
                    Text(title)
                        .font(Theme.title)
                        .tracking(Theme.lockTitle)
                        .foregroundStyle(Theme.font)
                    #endif
                    Text(button?.secondaryLine ?? "")
                        .font(Theme.small)
                        .foregroundStyle(Theme.fontQuiet)
                        .lineLimit(1)
                }
                .padding(.horizontal, Theme.margin(wide: wide))
                .padding(.bottom, 16)
            }
    }

    /// All chips at once, in place: skeleton chips of the real size until the core says the row is final
    /// (`proof.phase`), then the real chips in the same frame. No fade, no slide, no animation of any kind.
    private var proofRow: some View {
        let proof = button?.proof
        let settled = proof?.phase == .settled && proof?.visible == true
        let titleChips = proof?.phase != .settled || settled
        return ProofRow(waiting: proof?.phase != .settled,
                        directPlayFlag: settled && (proof?.directPlay ?? false),
                        hint: settled ? proof?.hint : nil,
                        ratingText: titleChips ? proof?.rating : nil,
                        sharing: titleChips ? proof?.ageRating : nil)
            .frame(height: 26, alignment: .leading)
            .transaction { $0.animation = nil }
    }

    /// **One button.** The core words it ("Weiter mit S2 · F3", "Staffel 1 starten", ...); until it knows, the
    /// button holds its place with a blank label.
    private var primaryButton: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlayMenu(versions: page?.model.versionsNext() ?? []) {
                launch(page?.model.playNext())
            } pick: { version in
                launch(page?.model.playNext(pick: version.id))
            } label: {
                ZStack {
                    Text(verbatim: " ").hidden()
                    if button?.labelReady == true {
                        HStack(spacing: 8) {
                            Image(icon: "play.fill", size: 15).font(.app(size: 15))
                                .opacity(prepares ? 0.5 : 1)
                            Text(verbatim: button?.label ?? "")
                        }
                    }
                }
                // The label is put in place when the next episode is known: no fade, no transition.
                .transaction { $0.animation = nil }
                .accessibilityLabel(Text(verbatim: button?.label ?? ""))
            }
            .buttonStyle(PrimaryButtonStyle(stretches: true, corner: Theme.primaryDetailCorner,
                                            progress: button?.progress.map(Double.init)))
            // The remaining time is not drawn any more (the line inside the button says it); VoiceOver still gets it.
            .accessibilityValue(Text(verbatim: button?.remaining ?? ""))
            // A tap starts the next episode's default version; a long press lists its versions (and only them).
            // **Gray while the next episode is still being found** (the core enables it, and enables it again
            // when the fresh load failed so that a press tries once more) and while a plan is on its way.
            .disabled(prepares || button?.enabled != true)
        }
        #if DEBUG
        .background { openMoreHook }
        #endif
    }

    private var actionRail: some View {
        let remembered = button?.favorite ?? false
        let watched = button?.watched ?? false
        return HStack(spacing: 8) {
            if watchlistShown {
                ActionButton(symbol: remembered ? "bookmark.fill" : "bookmark",
                             title: "Merkliste", active: remembered, stretches: true,
                             caption: remembered ? "Gemerkt" : "Merken") {
                    page?.model.setWatchlist(!remembered)
                }
            }
            // **The download button decides what sits here:** with it, "Laden" opens the episode selection
            // (the trailer then lives in the More panel); without it, "Trailer".
            if model.downloadButtonShow {
                ActionButton(symbol: "arrow.down", title: "Laden", stretches: true, caption: "Laden") {
                    selectionOpen = true
                }
            } else {
                ActionButton(symbol: "play.rectangle", title: "Trailer", stretches: true,
                             caption: "Trailer") { page?.model.trailer() }
            }
            ActionButton(symbol: watched ? "checkmark.circle.fill" : "checkmark.circle",
                         title: "Gesehen", active: watched, stretches: true,
                         caption: "Gesehen") {
                page?.model.setWatched(!watched)
            }
            ActionButton(symbol: "ellipsis", title: "Mehr", stretches: true, caption: "Mehr") { moreOpen = true }
                .asActionAnchor()
        }
    }

    @ViewBuilder
    private var description: some View {
        if let text = button?.overview ?? series.description {
            CollapsibleText(text: text)
        } else if seasonCountPending {
            // The fresh series has not answered: the text's three lines keep their place.
            DescriptionSlot()
        }
    }

    @ViewBuilder
    private var episodesList: some View {
        let part = page?.model.episodes
        VStack(alignment: .leading, spacing: 0) {
            // Where the viewer is could not be read: the page keeps what it knew (the seed's button and rows) and says so.
            if page?.model.button.stateFailed == true && page?.model.seasons.disturbed != true {
                DisturbHint(model: model) { page?.model.load() }
            }
            if page?.model.seasons.disturbed == true && seasonList.isEmpty {
                DisturbHint(model: model) { page?.model.load() }
            } else {
                switch part?.status {
                case .disturbed:
                    DisturbHint(model: model) { page?.model.retryEpisodes() }
                case .empty:
                    emptyHint(seasonList.isEmpty ? "Keine Folgen" : "Keine Folgen in dieser Staffel")
                case .ready:
                    episodeRows(part?.rows ?? [], more: part?.moreAvailable ?? false)
                default:
                    // The shape of the rows that are coming (shipping showed four), not a blank gap.
                    VStack(spacing: 0) {
                        ForEach(0 ..< 4, id: \.self) { _ in EpisodesPlaceholder() }
                    }
                }
            }
        }
    }

    private func episodeRows(_ rows: [EpisodeRow], more: Bool) -> some View {
        let items = page?.episodeItems() ?? [:]
        return VStack(spacing: 0) {
            ForEach(rows, id: \.id) { row in
                let episode = items[row.id] ?? Item(id: row.id, name: row.title, type: "Episode")
                SwipeRow(symbol: row.watched ? "arrow.uturn.backward" : "checkmark",
                         label: row.watched ? "Ungesehen" : "Gesehen",
                         action: { page?.model.setEpisodeWatched(row.id, !row.watched) },
                         onTap: { launch(page?.model.playEpisode(row.id)) }) {
                    EpisodesRow(model: model, episode: episode, ongoing: false, look: RustEpisodeLook(row: row))
                }
                .tileMenu(episode, model: model, landscape: true)
            }
            if more {
                MoreEpisodesButton {
                    withAnimation(Theme.reveal) { page?.model.moreEpisodes() }
                }
            }
        }
        .id(selectedSeason?.id)
        .transition(.opacity)
    }

    @ViewBuilder
    private var cast: some View {
        let folks = more?.cast ?? []
        if folks.isEmpty && more?.similarLoads != false {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 110), spacing: 14)],
                      spacing: Theme.gridRowGap) {
                ForEach(0 ..< 4, id: \.self) { _ in
                    VStack(spacing: 7) {
                        LoadField(corner: 38).frame(width: 76, height: 76)
                        LoadField(corner: 4).frame(width: 60, height: 12)
                    }
                    .frame(width: 84)
                }
            }
            .padding(.horizontal, Theme.margin(wide: wide))
            .padding(.top, 20)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Lädt")
        } else if folks.isEmpty {
            emptyHint("Keine Besetzung hinterlegt.")
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 110), spacing: 14)],
                      spacing: Theme.gridRowGap) {
                ForEach(folks, id: \.id) { person in
                    NavigationLink(value: PersonRoute(person: Person(core: person), origin: series.name)) {
                        CastTile(image: person.image.flatMap { URL(string: $0.address) },
                                 name: person.name, role: person.role)
                    }
                    .buttonStyle(Theme.PressButton())
                }
            }
            .padding(.horizontal, Theme.margin(wide: wide))
            .padding(.top, 20)
        }
    }

    private var extrasSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(more?.extras ?? [], id: \.id) { extra in
                    ExtraTile(model: model, extra: Item(rust: extra), look: RustTileLook(extra), prepares: $prepares,
                              missing: { message = String(localized: "Der Server hat keine Datei zu diesem Titel.") }) {
                        play = $0
                    }
                }
            }
            .padding(.horizontal, Theme.margin(wide: wide))
        }
        .padding(.top, 20)
    }

    @ViewBuilder
    private var similarSection: some View {
        let similar = more?.similar ?? []
        let missing = seerr?.similar ?? []
        if similar.isEmpty && missing.isEmpty && more?.similarFailed == true {
            DisturbHint(model: model) { page?.model.refresh() }
        } else if similar.isEmpty && missing.isEmpty && more?.similarLoads != false {
            GridPlaceholder(columns: Theme.columns(usableNow: gridWidth - 2 * Theme.margin(wide: wide),
                                                    wide: wide),
                              rails: 1)
                .padding(.horizontal, Theme.margin(wide: wide))
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
                .padding(.top, 20)
        } else if similar.isEmpty && missing.isEmpty {
            emptyHint("Nichts Ähnliches gefunden.")
        } else {
            let usableNow = gridWidth - 2 * Theme.margin(wide: wide)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.tileSpacing),
                                     count: Theme.columns(usableNow: usableNow, wide: wide)),
                      alignment: .leading, spacing: Theme.gridRowGap) {
                ForEach(similar, id: \.id) { tile in
                    NavigationLink(value: Item(rust: tile)) {
                        PosterTile(model: model, item: Item(rust: tile), width: nil)
                    }
                    .buttonStyle(Theme.PressButton())
                }
                // **Own titles first, then the ones Seerr could fetch**: dimmed poster, calm capsule.
                ForEach(missing) { card in
                    NavigationLink(value: card.route) { SeerrTile(card: card) }
                        .buttonStyle(Theme.PressButton())
                }
            }
            .padding(.horizontal, Theme.margin(wide: wide))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
            .padding(.top, 20)
        }
    }

    private func emptyHint(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .growing(15)
            .foregroundStyle(Theme.fontVeryQuiet)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 40)
    }

    // MARK: Downloads

    /// The seasons as the episode selection takes them.
    private var seasonItems: [Item] {
        seasonList.map { page?.item($0.id) ?? Item(id: $0.id, name: $0.name, type: "Season") }
    }

    /// The open season's episodes as `Item`s, in the list's order.
    private var openEpisodes: [Item] {
        let items = page?.episodeItems() ?? [:]
        return (page?.model.episodes.rows ?? []).compactMap { items[$0.id] }
    }

    private func entries(_ episode: Item) -> DownloadItem? {
        guard let account = model.session?.storageAccount else { return nil }
        let source = episode.mediaSources?.first
        return DownloadItem(
            id: episode.id, account: account, art: .episode, title: episode.name,
            series: current.name, seriesIdentifier: current.id,
            season: episode.parentIndexNumber ?? selectedSeason?.number.map(Int.init),
            episode: episode.indexNumber,
            runtimeTicks: episode.runTimeTicks, container: source?.container,
            source: source?.id, bytes: source?.size ?? 0,
            watchState: episode.userData, videoCodec: source?.videoCodec)
    }

    private var loadImages: [String: URL] {
        var card: [String: URL] = [:]
        if let poster = model.imageURL(for: current, maxHeight: 600, portrait: true) {
            card[current.id] = poster
        }
        let points = max(pagesWidth, Theme.heroHeightValue * 16 / 9)
        if let header = model.headerImageURL(for: current, width: Int((points * pixelMetric).rounded(.up))) {
            card[DownloadManager.headerKey(current.id)] = header
        }
        for p in loadItem {
            if let f = openEpisodes.first(where: { $0.id == p.id }),
               let image = model.imageURL(for: f, maxHeight: 220) {
                card[p.id] = image
            }
        }
        return card
    }

    /// The selection closes first, then the load sheet slides in.
    private func sheetShow(_ newOne: [DownloadItem], title: String) {
        loadItem = newOne
        loadTitle = title
        Task { @MainActor in
            if selectionOpen { try? await Task.sleep(for: .milliseconds(260)) }
            loadSheet = true
        }
    }

    // MARK: What the core asks of the host

    /// The tiles under the page: the core's own pictures and wording, found by id.
    private func rememberLooks(_ part: MorePart) {
        var looks: [String: RustTileLook] = [:]
        for tile in part.similar + part.extras { looks[tile.id] = RustTileLook(tile) }
        model.rustLooks.merge(looks) { _, new in new }
    }

    private func drain() {
        guard let page else { return }
        for effect in page.model.takeEffects() {
            switch effect {
            case .play(let action):
                launch(action)
            case .playTrailer(let id):
                Theme.jerk(.medium)
                PlayRequest.start(Item(id: id, name: current.name), freshValue: true, model: model, prepares: $prepares,
                                  missing: { message = String(localized: "Der Server hat keine Datei zu diesem Titel.") },
                                  play: { play = $0 })
            case .openWeb(let address):
                #if os(iOS)
                if let url = URL(string: address) { Task { await UIApplication.shared.open(url) } }
                #endif
            case .menu(let kind):
                hostMenu(kind)
            case .stateChanged:
                SeriesCache.shared.forget(current.id)
                model.noteWatchStateChanged()
            case .watchlistChanged:
                model.noteWatchlistChanged()
            }
        }
    }

    /// The menu entries only the platform can carry out.
    private func hostMenu(_ kind: MenuKind) {
        let state = page?.next ?? current
        switch kind {
        case .playOn(let id, _):
            guard let target = PlayOutputs.shared.targets.compactMap(PlayOutput.init(session:)).first(where: { $0.deviceID == id })
            else { return }
            Task { await PlayOutputs.shared.play(state, to: target, model: model) }
        case .together:
            SharedModel.shared.createFor = state
        case .shuffle:
            Task {
                guard let first = await model.shuffleStart(current) else {
                    message = AppModel.episodeNotLoaded
                    return
                }
                episodeStart(first, since: 0)
            }
        default:
            break
        }
    }

    /// What a press on Play (or a menu entry that plays) does, as the core decides it.
    ///
    /// `since` overrides the core's start second.
    private func launch(_ action: PlayAction?, since: Double? = nil) {
        guard let page, let action else { return }
        Theme.jerk(.medium)
        switch action {
        case .wait:
            return
        case .resolve(let id, let at):
            // The list entry has no `MediaSources`: the plan is asked for the episode itself, and its default version starts.
            guard !prepares, let episode = page.item(id) else { return }
            PlayRequest.start(episode, since: since ?? at,
                              model: model, prepares: $prepares,
                              missing: { message = AppModel.episodeNotLoaded }) { play = $0 }
        case .start(let id, let at, let source):
            guard let episode = page.item(id) else {
                message = AppModel.episodeNotLoaded
                return
            }
            let start = since ?? at
            let downloaded = model.downloads.file(for: id) != nil
            // The plan the page already holds (the next episode's), unless a version was picked or a copy on
            // the device decides.
            if source == nil, !downloaded, let plan = page.plan(app: model, for: id) {
                play = PlayRequest(item: episode, plan: plan, startAt: start)
                return
            }
            PlayRequest.start(episode, since: start, sourceID: source, model: model, prepares: $prepares,
                              missing: { message = AppModel.episodeNotLoaded }) { play = $0 }
        }
    }

    private func episodeStart(_ episode: Item, since: Double) {
        PlayRequest.start(episode, since: since,
                          model: model, prepares: $prepares,
                          missing: { message = AppModel.episodeNotLoaded }) { play = $0 }
    }

    private var sheetTitle: String {
        guard let state = page?.next, let st = state.parentIndexNumber, let fo = state.indexNumber else {
            return title
        }
        return "\(title) · " + String(localized: "S\(st) · F\(fo)")
    }

    /// The long-press menu of the "Mehr" sheet: the core names the entries, the host runs what only it can.
    private var moreActions: [TitleAction] {
        guard let page else { return [] }
        return page.model.moreMenu().map { entry in
            TitleAction(symbol: Self.symbol(of: entry.kind), wording: entry.text) {
                page.model.menu(entry.kind)
            }
        } + seerrMenu.actions(model: model, item: current)
    }

    private static func symbol(of kind: MenuKind) -> String {
        switch kind {
        case .trailer: "film"
        case .playOn: "tv"
        case .playEpisodeFromStart: "gobackward"
        case .together: "person.2"
        case .nextEpisode: "forward.end.alt"
        case .shuffle: "shuffle"
        case .markSeasonWatched: "checkmark.circle"
        case .refreshMetadata: "arrow.clockwise"
        default: "ellipsis"
        }
    }
}

/// Placeholder of a `EpisodesRow`: **the same layout**, `EpisodesRowsLayout`, only
/// with loading fields instead of image and text. It used to be a separate
/// rebuild (first 132 × 74 with 10 padding, then with fixed-width bars and its
/// own offset); the rows were taller or different from the real ones, and the
/// list jumped when the episodes arrived.
struct EpisodesPlaceholder: View {
    var body: some View {
        EpisodesRowsLayout(title: Text(verbatim: "10. Folgentitel"),
                           secondaryLine: Text(verbatim: "45 min"),
                           placeholder: true) {
            LoadField().frame(width: Theme.episodeWidth, height: Theme.episodeHeight)
        }
        .accessibilityHidden(true)
    }
}

/// The row in which an episode and its placeholder sit: one layout so both have
/// the same dimensions.
struct EpisodesRowsLayout<Preview: View>: View {
    @Environment(\.wide) private var wide
    let title: Text
    let secondaryLine: Text
    var titleColor: Color = Theme.font
    /// The text is invisible but holds the row height; a loading field of its width
    /// lies on top.
    var placeholder = false
    @ViewBuilder let preview: Preview

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            preview

            VStack(alignment: .leading, spacing: 3) {
                title
                    // Title of a row with an image: 15 semibold. It used to be 14 medium, a size
                    // that appears in no step of the scale, which made the row quieter than any
                    // ordinary list row although it carries the same content.
                    // **Scaling, not fixed**: a row with an image is a list row, and lists
                    // follow the system font. Fixed on this page are the poster, the badges and the
                    // tabular file details.
                    .growing(15, .semibold)
                    .foregroundStyle(placeholder ? .clear : titleColor)
                    .overlay { if placeholder { LoadField(corner: 3).padding(.vertical, 3) } }
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                secondaryLine
                    // The detail under the title grows with it, otherwise half the row would follow
                    // the system font and the other half not.
                    .growing(12)
                    .foregroundStyle(placeholder ? .clear : Theme.fontVeryQuiet)
                    .overlay { if placeholder { LoadField(corner: 3).padding(.vertical, 3) } }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.margin(wide: wide))
        .padding(.vertical, 14)
    }
}

/// An episode in the list: thumbnail, number, runtime, progress.
struct EpisodesRow: View {
    @Environment(\.wide) private var wide
    let model: AppModel
    let episode: Item
    /// The episode that is currently playing; in the player, the one being watched.
    ///
    /// **A larger image, not a surface.** It last carried a white 8 % surface, and in
    /// the player that ran across the **full width**: a continuous strip to both
    /// edges. On iPhone it passes under the Dynamic Island and makes it visible, in a
    /// layer where it is normally not noticed.
    ///
    /// Now the thumbnail grows to the right while staying flush on the left with the
    /// others. That says the same without pulling a surface to the edge, and says it
    /// on the object itself.
    var ongoing = false
    /// The core's wording (`AppModel.coreServes`); `nil` shows the Swift one.
    var look: RustEpisodeLook?

    private var watched: Bool { look?.watched ?? episode.userData?.played ?? false }
    private var loaded: DownloadItem? { model.downloads.entries(for: episode.id) }

    var body: some View {
        // **The right column belongs to the download, and to it alone.**
        //
        // The checkmark for "watched" used to be here. A second round symbol next to it
        // would be the same search picture we already had with two checkmarks: two
        // shapes side by side meaning different things. The checkmark moved onto the
        // thumbnail, where the progress bar already is, the answer to "how far am I",
        // and the checkmark is its end.
        //
        // Netflix does the same: only the arrow on the right, the watch state on the
        // image. Prime Video puts both in one column, which is exactly where it becomes
        // ambiguous.
        // **No surface.** The episode the big button points at carried a white 8 %
        // surface; on the device it looked like a selection nobody made. What `ongoing`
        // does today is at the field: the image grows.
        EpisodesRowsLayout(title: Text(verbatim: look?.title ?? "\(episode.indexNumber.map { "\($0). " } ?? "")\(episode.name)"),
                           secondaryLine: Text(secondaryLine).monospacedDigit(),
                           // **Watched recedes, it does not vanish.** The dimmed title is the third signal
                           // besides the darkened image and the checkmark on it.
                           titleColor: watched ? Theme.fontQuiet : Theme.font) {
            preview
        }
        .contentShape(Rectangle())
        // **One announcement per episode.** VoiceOver used to read the fragments
        // separately, plus "checkmark" for the watched mark on the image, and whether the
        // episode is downloaded did not appear at all.
        .accessibilityElement(children: .ignore)
        // The stand-in item of a row without its JSON has no index: the core's own title ("3. Name") then
        // carries the number, so "Folge n" is never dropped.
        .accessibilityLabel(Text(verbatim: [
            look?.title ?? [
                episode.indexNumber.map { String(localized: "Folge \($0)") }, episode.name,
            ].compactMap { $0 }.joined(separator: ", "),
            secondaryLine.isEmpty ? nil : secondaryLine,
        ].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityValue(Text(verbatim: [
            episode.tileState,
            loaded?.state == .done ? String(localized: "geladen") : "",
        ].filter { !$0.isEmpty }.joined(separator: ", ")))
    }

    /// The thumbnail carries the watch state: started as a bar, watched as a
    /// checkmark on a darkened background. The same badge as at top right on a poster
    /// tile; no new symbol, just one more place.
    /// 134 instead of 152, same aspect ratio: large enough to see without
    /// comparison, small enough that the row does not fall out of the list.
    private var imageWidthValue: CGFloat { ongoing ? Theme.episodeWidthOngoing : Theme.episodeWidth }

    private var preview: some View {
        // Split into named values: with the BlurHash argument the single expression no longer type-checks in time.
        let width: CGFloat = imageWidthValue
        let height: CGFloat = width * Theme.episodeHeight / Theme.episodeWidth
        let address: URL? = look?.image ?? model.imageURL(for: episode, maxHeight: 280)
        let own: Double? = look?.progress ?? episode.userData?.playedPercentage.map { $0 / 100 }
        // A full bar **and** a checkmark would be the same information twice.
        let share: Double? = watched ? nil : own
        return Picture(url: address, width: width, height: height, corner: Theme.cornerTile,
                       progress: share, blur: look?.blur)
            .watchedCheckmark(watched)
    }


    private var secondaryLine: String {
        if let look { return look.secondaryLine }
        // `runtimeSeconds` is 0, not nil, for an episode without a value; the rule in
        // the package catches both. This exact check was once missing on TV, and the
        // series showed "0 min.".
        guard let minutes = DisplayRules.runtimeMinutes(seconds: episode.runtimeSeconds) else { return "" }
        // Runtime only: the file size is in the load selection, and on the episode it is
        // a number without a question behind it.
        return episode.remainingTimeText ?? String(localized: "\(minutes) Min.")
    }
}

/// Episode list in sections: each row carries its own swipe area and an image
/// fetch; 500 of them at once would be sluggish and expensive.
enum EpisodesSection {
    static let step = 40
}

/// "Show more episodes" at the end of a section.
struct MoreEpisodesButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Weitere Folgen anzeigen")
                .growing(15, .semibold)
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, minHeight: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressRow())
    }
}

/// Episode list of a season, for the route via the library.
struct SeasonView: View {
    let model: AppModel
    let series: Item
    let season: Item

    @State private var episodes: [Item] = []
    @State private var episodesCount = EpisodesSection.step
    @State private var loads = true
    @State private var disrupted = false
    @State private var play: PlayRequest?
    /// Guard against a second tap while the plan is still being fetched.
    /// It was missing here: the series page had it, the season view did not.
    @State private var prepares = false
    @State private var message: String?

    @Environment(\.wide) private var wide
    @Environment(\.dismiss) private var back

    var body: some View {
        ZStack {
            Theme.reason.ignoresSafeArea()
            VStack(spacing: 0) {
            // **Our header, not Apple's bar.**
            //
            // This page was the only one of twenty-three that showed Apple's system bar,
            // with its back arrow, its scale and its material. Every other subpage hides it
            // and carries `SubpageHeader` or `DetailHeader`. It was only noticed when
            // comparing all pages side by side; individually this never looks wrong.
            ScrollView {
                VStack(spacing: 0) {
                    // `loads` was unused here: during the fetch, with an empty season and with a
                    // silent server the page was the same blank surface.
                    if disrupted {
                        DisturbHint(model: model) { Task { await episodesLoad() } }
                    } else if loads {
                        VStack(spacing: 0) {
                            ForEach(0 ..< 4, id: \.self) { _ in
                                EpisodesPlaceholder()
                            }
                        }
                    } else if episodes.isEmpty {
                        Text("Keine Folgen in dieser Staffel")
                            .growing(15)
                            .foregroundStyle(Theme.fontVeryQuiet)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    ForEach(episodes.prefix(episodesCount)) { episode in
                        let watched = (episode.userData?.played ?? false)
                        SwipeRow(symbol: watched ? "arrow.uturn.backward" : "checkmark",
                                   label: watched ? "Ungesehen" : "Gesehen",
                                   action: { watchedToggle(episode) },
                                   onTap: { launch(episode) }) {
                            EpisodesRow(model: model, episode: episode)
                        }
                        // The same tile menu as on the series page.
                        .tileMenu(episode, model: model, landscape: true)
                        // No divider: the still image already separates. The same hand-built line as on
                        // the series page stood here; both are gone.
                    }
                    if episodes.count > episodesCount {
                        MoreEpisodesButton {
                            withAnimation(Theme.reveal) {
                                episodesCount += EpisodesSection.step
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            // The header is an inset of the scroll area with the same fade as the settings pages: the episodes run
            // underneath instead of being cut at a hard edge below it.
            .fadingUnderSubpageHeader(title: season.name) { back() }
            }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
        #if os(iOS)
        .playerCover(item: $play) { wish in
            PlayerScreen(model: model, item: wish.item,
                         plan: wish.plan, startAt: wish.startAt)
        }
        #endif
        .overlay {
            if let message { HintStrip(text: message) { self.message = nil } }
        }
        .task { await episodesLoad() }
        .catchUp(at: model.pagesRefresh) { Task { await episodesLoad() } }
    }

    private func episodesLoad() async {
        loads = true
        let fetched = await model.episodes(series: series.id, season: season.id)
        loads = false
        disrupted = fetched == nil
        if let fetched { episodes = fetched }
    }

    private func launch(_ episode: Item) {
        guard !prepares else { return }
        // On press, not after the fetch: a haptic tick half a second later feels
        // unrelated.
        Theme.jerk(.medium)
        // **An episode with several versions starts the default one, like a movie.**
        PlayRequest.start(episode, model: model, prepares: $prepares) { play = $0 }
    }
}

extension SeasonView {
    /// Toggle the watched state and refresh the list immediately so the checkmark
    /// does not appear only on the next load.
    func watchedToggle(_ episode: Item) {
        let new = !(episode.userData?.played ?? false)
        Task {
            guard await model.setWatched(episode, an: new) == nil else { return }
            // If the refetch fails, the list stays; the checkmark is set, which is the
            // answer that matters here.
            if let freshValue = await model.episodes(series: series.id, season: season.id) {
                episodes = freshValue
            }
        }
    }
}
