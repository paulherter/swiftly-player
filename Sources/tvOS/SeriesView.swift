import JellyfinKit
import SwiftUI
import SwiftlyCore

/// The series page: the same header as a movie, then the episodes, cast and
/// similar titles, each as its own `Section` row (no tabs).
/// Episodes are a horizontal strip of the same landscape tiles as "Continue
/// Watching".

struct SeriesView: View {
    let model: AppModel
    let series: Item
    var startSeasonID: String?
    var startEpisodeValue: Item?

    /// The page's data owner, the core's `SeriesVm` (`SeriesCore`); `nil` when there is no account.
    @State private var page: SeriesCore?

    @MainActor init(model: AppModel, series: Item,
                    startSeasonID: String? = nil, startEpisodeValue: Item? = nil) {
        self.model = model
        self.series = series
        self.startSeasonID = startSeasonID
        self.startEpisodeValue = startEpisodeValue
        // The season hint of the tile the user came through (id first, then number: the server does not
        // always send `SeasonId`); the core picks the season like the old selection rule did.
        _page = State(initialValue: SeriesCore(
            app: model, item: series, startSeasonID: startSeasonID ?? startEpisodeValue?.seasonId,
            startSeasonNumber: startEpisodeValue?.parentIndexNumber))
    }

    /// Rows and header fade in once the page is up, as before.
    @State private var inFade = false
    @State private var message: String?
    @Environment(\.playRequest) private var play
    @State private var prepares = false
    @State private var versionChoice: VersionChoice?
    @State private var versionPick: VersionPick?
    @State private var moreOpen = false
    @State private var seasonSelectionOpen = false
    @FocusState private var atEpisode: String?
    @FocusState private var atPrimaryButton: Bool
    @FocusState private var atMoreButton: Bool
    @FocusState private var atSeasonPill: Bool
    private enum FocusTarget: Equatable { case primaryButton, moreButton, episode(String) }
    @State private var lastFocus: FocusTarget = .primaryButton

    private var current: Item { page?.item ?? series }
    private var button: SeriesButtonPart? { page?.model.button }
    private var seasonList: [SeasonRow] { page?.model.seasons.seasons ?? [] }
    private var selectedSeason: SeasonRow? {
        let id = page?.model.seasons.selected
        return seasonList.first { $0.id == id }
    }
    private var more: MorePart? { page?.model.more }
    private var actors: [Person] { (more?.cast ?? []).map(Person.init(core:)) }
    private var similar: [Item] { (more?.similar ?? []).map(Item.init(rust:)) }
    private var extras: [Item] { (more?.extras ?? []).map(Item.init(rust:)) }
    private var episodes: [Item] {
        let items = page?.episodeItems() ?? [:]
        return (page?.model.episodes.rows ?? []).map {
            items[$0.id] ?? Item(id: $0.id, name: $0.title, type: "Episode")
        }
    }

    var body: some View {
        layout
            .defaultFocus($atPrimaryButton, true, priority: .userInitiated)
            .onChange(of: moreOpen) { _, opened in if !opened { atMoreButton = true } }
            .onChange(of: seasonSelectionOpen) { _, opened in if !opened { atSeasonPill = true } }
            .onChange(of: atPrimaryButton) { _, an in if an { lastFocus = .primaryButton } }
            .onChange(of: atMoreButton) { _, an in if an { lastFocus = .moreButton } }
            .onChange(of: atEpisode) { _, now in if let now { lastFocus = .episode(now) } }
            .onChange(of: play.wrappedValue == nil) { before, closed in
                guard closed, before == false else { return }
                focusBack()
            }
            .onChange(of: SharedModel.shared.createFor == nil) { before, toward in
                guard toward, before == false, play.wrappedValue == nil else { return }
                focusBack()
            }
            .modifier(CoreLifecycle(run: {
                atPrimaryButton = true
                withAnimation(Theme.motion(.timingCurve(0.23, 1, 0.32, 1, duration: 0.22))) { inFade = true }
                await page?.run(app: model)
            }))
            .onChange(of: model.pagesRefresh) { _, _ in page?.model.refresh() }
            .onChange(of: button?.effectSeq) { _, _ in drain() }
            .onChange(of: button?.message) { _, new in if let new { message = new } }
            .onChange(of: button?.toggleError) { _, new in if let new { message = new } }
            .onChange(of: model.watchersShown) { _, _ in page?.send(options: model) }
            .onChange(of: PlayOutputs.shared.targets.map(\.id)) { _, _ in page?.send(options: model) }
    }

    private var layout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                railsSection {
                    HStack(spacing: 24) {
                        RailTitle(text: "Folgen")
                        if seasonList.count > 1 || selectedSeason != nil {
                            SeasonPill(name: selectedSeason?.name ?? seasonList.first?.name ?? String(localized: "Staffel 1"),
                                       opened: $seasonSelectionOpen)
                                .focused($atSeasonPill)
                                .panelTrigger("staffel")
                        }
                    }
                } content: {
                    episodesStrip
                }
                .opacity(inFade ? 1 : 0)

                WatchersStrip(model: model, item: series,
                              fromCore: (more?.watchers ?? []).map(Watcher.init(core:)))
                    .opacity(inFade ? 1 : 0)

                if !actors.isEmpty {
                    railsSection {
                        RailTitle(text: "Besetzung")
                    } content: {
                        CastStrip(model: model, folks: actors, origin: current.name)
                    }
                    .opacity(inFade ? 1 : 0)
                    .transition(.opacity)
                }
                if more?.similarFailed == true, similar.isEmpty {
                    railsSection {
                        RailTitle(text: "Ähnliches")
                    } content: {
                        DisturbState(model: model, retry: { page?.model.refresh() })
                            .frame(height: Theme.posterHeight)
                    }
                    .opacity(inFade ? 1 : 0)
                    .transition(.opacity)
                } else if !similar.isEmpty {
                    railsSection {
                        RailTitle(text: "Ähnliches")
                    } content: {
                        TitleStrip(model: model, items: similar)
                    }
                    .opacity(inFade ? 1 : 0)
                    .transition(.opacity)
                }
                if !extras.isEmpty {
                    railsSection {
                        RailTitle(text: "Extras")
                    } content: {
                        TitleStrip(model: model, items: extras) { extra in
                            PlayRequest.start(extra, since: 0, model: model, prepares: $prepares,
                                              missing: { message = String(localized: "Der Server hat keine Datei zu diesem Titel.") },
                                              play: { play.wrappedValue = $0 })
                        }
                    }
                    .opacity(inFade ? 1 : 0)
                    .transition(.opacity)
                }
            }
            .padding(.bottom, Theme.completionPadding)
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea()
        .imageReason(url: model.landscapeImageURL(for: current, width: 1600)
                        ?? model.headerImageURL(for: current))
        .disabled(moreOpen || seasonSelectionOpen)
        .panel(under: seasonSelectionOpen ? "staffel" : nil) {
            ActionPanel(actions: seasonActions, opened: $seasonSelectionOpen,
                        start: seasonList.firstIndex { $0.id == selectedSeason?.id } ?? 0)
                .transition(.opacity)
        }
        .panel(under: moreOpen ? "mehr" : nil) {
            ActionPanel(actions: moreActions, opened: $moreOpen)
                .transition(.opacity)
        }
        .animation(Theme.motion(.timingCurve(0.23, 1, 0.32, 1, duration: 0.22)), value: moreOpen)
        .animation(Theme.motion(.timingCurve(0.23, 1, 0.32, 1, duration: 0.22)), value: seasonSelectionOpen)
        .versionChoice($versionChoice) { choice, version in
            PlayRequest.start(choice, picking: version, model: model, prepares: $prepares,
                              missing: { message = AppModel.episodeNotLoaded },
                              play: { play.wrappedValue = $0 })
        }
        .versionPick($versionPick) { choice, version in
            guard let page else { return }
            let id = choice.itemId
            let action = (id == nil || id == button?.nextEpisode)
                ? page.model.playNext(pick: version.id) : page.model.playEpisode(id!, pick: version.id)
            launch(action, since: choice.since)
        }
        .overlay(alignment: .top) {
            if let message {
                HintStrip(text: message) { self.message = nil; page?.model.dismissMessage() }
                    .padding(.top, Theme.edgeTop)
            }
        }
    }

    private struct CoreLifecycle: ViewModifier {
        let run: () async -> Void
        func body(content: Content) -> some View { content.task { await run() } }
    }

    // MARK: Header

    /// **One button, the core words it** ("Weiter mit S2 · F3", "Staffel 1 starten", ...); until it knows, the
    /// button holds its place with a blank label.
    private var header: some View {
        let remembered = button?.favorite ?? false
        return DetailHeader(model: model, item: current, plan: page?.next.flatMap { page?.plan(app: model, for: $0.id) },
                            heroTrim: 40) {
            HStack(spacing: 24) {
                Button { launch(page?.model.playNext()) } label: {
                    ZStack(alignment: .leading) {
                        Label(String(localized: "Abspielen \("S00 • F00")"), icon: "play.fill")
                            .hidden()
                            .accessibilityHidden(true)
                        if button?.labelReady == true {
                            Label(button?.label ?? "", icon: "play.fill")
                        }
                    }
                    .transaction { $0.animation = nil }
                }
                .buttonStyle(ThemedButtonStyle())
                .disabled(prepares || button?.enabled != true)
                .focused($atPrimaryButton)
                .tileMenu(current, model: model)

                if begun {
                    Button { launch(page?.model.playNext(), since: 0) } label: {
                        Image(icon: "arrow.counterclockwise").font(Theme.button)
                    }
                    .buttonStyle(ThemedButtonStyle(onlySymbol: true))
                    .accessibilityLabel(Text("Von vorn"))
                    .disabled(prepares)
                }

                if model.watchlistShown {
                    Button { page?.model.setWatchlist(!remembered) } label: {
                        Image(icon: remembered ? "bookmark.fill" : "bookmark").font(Theme.button)
                    }
                    .buttonStyle(ThemedButtonStyle(onlySymbol: true, active: remembered))
                    .accessibilityLabel(Text("Merkliste"))
                    .accessibilityAddTraits(remembered ? [.isButton, .isSelected] : .isButton)
                }

                RowExtraButtons(watched: button?.watched ?? false, actions: rowActions,
                                onWatched: { page?.model.setWatched(!(button?.watched ?? false)) },
                                onShuffle: { page?.model.menu(.shuffle) },
                                onTogether: { page?.model.menu(.together) })

                MoreButton(opened: $moreOpen)
                    .focused($atMoreButton)
                    .panelTrigger("mehr")
            }
            .opacity(inFade ? 1 : 0)
        }
    }

    private var rowActions: TVRowActions { TVRowActions(menu: page?.model.moreMenu() ?? []) }

    /// Whether the next episode is already started: only then "Von vorn" is a button of its own.
    private var begun: Bool {
        (page?.next?.userData?.playbackPositionTicks ?? 0) > 0
    }

    // MARK: Episodes

    @ViewBuilder
    private var episodesStrip: some View {
        let height = Theme.landscapeHeight + 2 * Theme.railsPadding + 80
        ZStack(alignment: .topLeading) {
            if page?.model.seasons.disturbed == true && seasonList.isEmpty {
                DisturbState(model: model, retry: { page?.model.load() })
                    .frame(height: height)
            } else {
            switch page?.model.episodes.status {
            case .ready:
                EpisodesStrip(model: model, episodes: episodes,
                              nextWith: episodeFront, atEpisode: $atEpisode) { episode in
                    launch(page?.model.playEpisode(episode.id))
                }
                .equatable()
                .id(episodes.first?.id ?? "leer")
                .transition(.opacity)
            case .disturbed:
                DisturbState(model: model, retry: { page?.model.retryEpisodes() })
                    .frame(height: height)
            case .empty:
                EmptyState(symbol: "rectangle.stack",
                           title: seasonList.isEmpty ? "Keine Folgen" : "Keine Folgen in dieser Staffel",
                           button: ("Erneut versuchen", { page?.model.retryEpisodes() }))
                    .frame(height: height)
            default:
                // Landscape tiles in their final size instead of a blank strip.
                HStack(spacing: 40) {
                    ForEach(0 ..< 4, id: \.self) { _ in
                        LoadField().frame(width: Theme.landscapeWidth, height: Theme.landscapeHeight)
                    }
                }
                .padding(.top, Theme.railsPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Lädt")
            }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// The next episode's id when it is in the open season: it gets the initial focus.
    private var episodeFront: String? {
        guard let state = page?.next,
              state.seasonId == selectedSeason?.id,
              episodes.contains(where: { $0.id == state.id })
        else { return nil }
        return state.id
    }

    private var seasonActions: [TitleAction] {
        seasonList.map { season in
            TitleAction(symbol: selectedSeason?.id == season.id ? "checkmark.circle.fill" : "circle",
                        wording: season.name) {
                guard selectedSeason?.id != season.id else { return }
                page?.model.selectSeason(season.id)
            }
        }
    }

    private func focusBack() {
        switch lastFocus {
        case .primaryButton: atPrimaryButton = true
        case .moreButton: atMoreButton = true
        case .episode(let id):
            if episodes.contains(where: { $0.id == id }) { atEpisode = id }
            else if let front = episodeFront { atEpisode = front }
            else { atPrimaryButton = true }
        }
    }

    // MARK: More panel

    /// The core's menu without what the row shows as buttons; the host runs what only it can.
    private var moreActions: [TitleAction] {
        guard let page else { return [] }
        return rowActions.panel.map { entry in
            TitleAction(symbol: Self.symbol(of: entry.kind), wording: entry.text) {
                page.model.menu(entry.kind)
            }
        }
    }

    private static func symbol(of kind: MenuKind) -> String {
        switch kind {
        case .playOn: "tv"
        case .playFromStart: "gobackward"
        case .resetProgress: "arrow.counterclockwise.circle"
        case .together: "person.2"
        case .shuffle: "shuffle"
        case .refreshMetadata: "arrow.clockwise"
        default: "ellipsis"
        }
    }

    // MARK: What the core asks of the host

    private func drain() {
        guard let page else { return }
        for effect in page.model.takeEffects() {
            switch effect {
            case .play(let action):
                launch(action)
            case .playTrailer(let id):
                PlayRequest.start(Item(id: id, name: current.name), freshValue: true, model: model, prepares: $prepares,
                                  missing: { message = String(localized: "Der Server hat keine Datei zu diesem Titel.") },
                                  play: { play.wrappedValue = $0 })
            case .menu(let kind):
                hostMenu(kind)
            case .stateChanged:
                SeriesCache.shared.forget(current.id)
                model.noteWatchStateChanged()
            case .watchlistChanged:
                model.noteWatchlistChanged()
            case .openWeb:
                break
            }
        }
    }

    private func hostMenu(_ kind: MenuKind) {
        let state = page?.next ?? current
        switch kind {
        case .playOn(let id, _):
            guard let target = PlayOutputs.shared.targets.compactMap(PlayOutput.init(session:))
                .first(where: { $0.deviceID == id })
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
    private func launch(_ action: PlayAction?, since: Double? = nil) {
        guard let page, let action else { return }
        switch action {
        case .wait:
            return
        case .choose(let id, let at, let versions):
            versionPick = VersionPick(
                heading: String(localized: "Fassung wählen"), options: versions, since: since ?? at, itemId: id)
        case .resolve(let id, let at):
            // The list entry has no `MediaSources`: the app fetches the full episode and asks itself.
            guard !prepares, let episode = page.item(id) else { return }
            PlayRequest.start(episode, since: since ?? at,
                              ask: VersionAsk(choose: { versionChoice = $0 }, failed: { message = $0 }),
                              model: model, prepares: $prepares,
                              missing: { message = AppModel.episodeNotLoaded }) { play.wrappedValue = $0 }
        case .start(let id, let at, let source):
            guard let episode = page.item(id) else {
                message = AppModel.episodeNotLoaded
                return
            }
            let start = since ?? at
            let downloaded = model.downloads.file(for: id) != nil
            if source == nil, !downloaded, let plan = page.plan(app: model, for: id) {
                play.wrappedValue = PlayRequest(item: episode, plan: plan, startAt: start)
                return
            }
            PlayRequest.start(episode, since: start, sourceID: source, model: model, prepares: $prepares,
                              missing: { message = AppModel.episodeNotLoaded }) { play.wrappedValue = $0 }
        }
    }

    private func episodeStart(_ episode: Item, since: Double) {
        PlayRequest.start(episode, since: since,
                          ask: VersionAsk(choose: { versionChoice = $0 }, failed: { message = $0 }),
                          model: model, prepares: $prepares,
                          missing: { message = AppModel.episodeNotLoaded }) { play.wrappedValue = $0 }
    }
}
