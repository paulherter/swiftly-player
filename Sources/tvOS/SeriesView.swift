import JellyfinKit
import SwiftUI

/// The series page: the same header as a movie, then the episodes, cast and
/// similar titles, each as its own `Section` row (no tabs).
/// Episodes are a horizontal strip of the same landscape tiles as "Continue
/// Watching".

struct SeriesView: View {
    let model: AppModel
    let series: Item
    /// When opened via a single episode, that episode's season is already selected.
    var startSeasonID: String?
    /// **That episode is also where playback continues.**
    /// The main button would otherwise wait for `stateInSeries`, a fetch whose
    /// result the caller already holds. Coming from "Continue Watching" or
    /// "Next Episode", the opened episode is exactly what the button should name.
    /// Only an initial value: `load()` fetches the fresh state and overwrites it.
    /// Opened directly from the library there is none, so the fetch stays, and
    /// `SeriesCache` serves it the second time.
    var startEpisodeValue: Item?

    /// **The initial state comes from the cache, not from nothing.**
    /// Same reasoning as `ImageReason` and `Backdrop`: a value delivered later
    /// arrives after the empty first pass, and that pass is the "Loading…". See
    /// `SeriesCache`.
    @MainActor init(model: AppModel, series: Item,
                    startSeasonID: String? = nil, startEpisodeValue: Item? = nil) {
        self.model = model
        self.series = series
        self.startSeasonID = startSeasonID
        self.startEpisodeValue = startEpisodeValue

        let remembered = SeriesCache.shared.state(series.id, with: model)
        _seasons = State(initialValue: remembered?.seasons ?? [])
        // **Never a guessed episode, but the right one immediately.** `startEpisodeValue` is
        // the tile the user came through: the right episode from "Continue Watching"
        // and "Next Episode", but the newest one from "Recently Added", which showed
        // the wrong "Play S5 E10" for a second until the real state said E1.
        // So the cache comes first: the home page remembers the episodes from
        // "Continue Watching" and "Next Episode", and a focused tile fetches its
        // series state before the click (`SeriesCache.nextPreload`). A
        // started start episode counts without it. Otherwise the button stays
        // neutral until `load()` delivers the state.
        let begun = (startEpisodeValue?.userData?.playbackPositionTicks ?? 0) > 0
        let beginning = SeriesCache.shared.nextEpisode(series.id, with: model)
            ?? (begun ? startEpisodeValue : nil)
        _nextWith = State(initialValue: beginning)
        _statePresent = State(initialValue: beginning != nil)

        // The season `load()` would pick, so coming back shows the last watched
        // season rather than the first. The next-episode rule from the package: the episode's hint
        // (id, then number, since the server does not always send `SeasonId`) comes
        // before the state.
        let season = SeasonSelectionRule.choose(from: remembered?.seasons ?? [],
                                              hintID: startSeasonID ?? startEpisodeValue?.seasonId,
                                              hintNumber: startEpisodeValue?.parentIndexNumber,
                                              state: beginning)
        _selectedSeason = State(initialValue: season)

        let episodes = season.flatMap { remembered?.episodes[$0.id] } ?? []
        _episodes = State(initialValue: episodes)
        _loadsEpisodes = State(initialValue: episodes.isEmpty)
    }

    /// **New content fades in on appearing, not on loading.**
    /// The fade used to hang on data arriving. Since the caches, the data is
    /// already there in the first pass, so there was nothing to animate: soft
    /// the first time, hard from the second. Hanging it on appearing fades in
    /// **every time**, whether or not the data is already there.
    @State private var inFade = false

    @State private var freshValue: Item?
    @State private var plan: PlaybackPlan?
    @State private var seasons: [Item]
    @State private var selectedSeason: Item?
    /// **Did the user pick the season?** Only then it stays put on loading.
    /// The `init` choice comes from the `SeriesCache`, i.e. old state: after
    /// moving on to the next season the old one showed, `episodeFront` was `nil`
    /// (the episode is not in the shown season), and the row began at E1.
    @State private var seasonSelfSelected = false
    @State private var episodes: [Item]
    @State private var loadsEpisodes: Bool
    @State private var remembered = false
    @State private var watched = false
    @State private var message: String?
    /// The player sits in the frame; see `MainView`.
    @Environment(\.playRequest) private var play
    @State private var prepares = false
    @State private var nextWith: Item?
    /// Whether `nextWith` is a known state: from the cache, a started start
    /// episode or the server. Until then the button reads "Abspielen".
    @State private var statePresent: Bool
    /// Counts the load runs of `load()`; only the newest writes.
    @State private var loadRun = 0
    @State private var similar: [Item] = []
    /// Extras of the series; empty means no row.
    @State private var extras: [Item] = []
    /// **Empty and failed are two cases.** Without these flags the page said
    /// "Keine Folgen in dieser Staffel" when the server had been silent, and the
    /// "Ähnliches" row silently disappeared.
    @State private var episodesDisturbed = false
    @State private var similarDisturbed = false
    @State private var moreOpen = false
    /// Which episode tile has focus.
    @FocusState private var atEpisode: String?
    /// Whether the main button has focus; it is the page's starting point.
    @FocusState private var atPrimaryButton: Bool
    /// **Where focus returns when a panel closes.**
    /// It used to jump to the main button, the page's initial focus, even though
    /// the user stood at the More button. A panel is not a change of place but
    /// something that opens above its button; closing it returns to the button
    /// that opened it.
    @FocusState private var atMoreButton: Bool
    /// Which season chip has focus; see `seasonRow`.
    @FocusState private var atSeason: String?
    /// Which season sits in view in the season row; see `seasonRow`.
    @State private var seasonFront: String?
    /// **Where focus returns when the player closes.**
    /// Same reason as `atMoreButton`. The player is a sibling in the frame and
    /// the page stays mounted during playback, only `disabled`, which resets the
    /// focus variables. Without this memory tvOS picks something geometrically
    /// on removal and lands on the first tab of the header bar instead of the
    /// episode, season or button where the user stood.
    private enum FocusTarget: Equatable { case primaryButton, moreButton, season(String), episode(String) }
    @State private var lastFocus: FocusTarget = .primaryButton

    private var current: Item { freshValue ?? series }
    private var actors: [Person] { (current.people ?? []).filter(\.isCast) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                railsSection {
                    RailTitle(text: "Folgen")
                } content: {
                    VStack(alignment: .leading, spacing: 0) {
                        seasonRow
                        episodesStrip
                    }
                }
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
                if similarDisturbed, similar.isEmpty {
                    // The row used to vanish silently here. A series with nothing related needs
                    // no section, but a silent server does.
                    railsSection {
                        RailTitle(text: "Ähnliches")
                    } content: {
                        DisturbState(model: model,
                                     retry: { Task { await similarLoad() } })
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
                    // Something to play: selecting starts the extra, as on the movie page.
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
        // Margins as on the movie page; see there.
        .ignoresSafeArea()
        // **The whole page background tints to the backdrop.**
        // **After `ignoresSafeArea`, not before.** Before, it got the area reduced
        // by the safe area (1760 x 960 instead of 1920 x 1080). The mesh computes in
        // fractions of its area, so it sat differently than on the home page, and
        // opening showed the difference as shrinking. The home page applied it after
        // `ignoresSafeArea` from the start.
        // On the page and not on the header: otherwise the tint ends at its bottom
        // edge and a seam crosses the screen. See `ImageReason`.
        .imageReason(url: model.landscapeImageURL(for: current, width: 1600)
                        ?? model.headerImageURL(for: current))
        // **While a panel is open, the rest is not a focus target.**
        // `focusSection` does not hold focus, it only orders it. A left or right
        // press used to jump out of the open panel into the episodes behind it, and
        // the panel stayed until the page was left.
        // Locking happens **before** the modifiers: the panels hang after and so
        // stay operable themselves.
        .disabled(moreOpen)
        // It sits under its button, at its edge; see `PanelAnchor`. A number computed
        // from the page layout landed offset by the safe margin and would have needed
        // re-tuning with every added row.
        .panel(under: moreOpen ? "mehr" : nil) {
            ActionPanel(actions: moreActions, opened: $moreOpen)
                .transition(.opacity)
        }
        .animation(Theme.motion(.easeInOut(duration: 0.18)), value: moreOpen)
        .overlay(alignment: .top) {
            if let message {
                HintStrip(text: message) { self.message = nil }
                    .padding(.top, Theme.edgeTop)
            }
        }
        // **On opening, focus is on the running episode.**
        // The strip is scrolled there anyway; without an assignment tvOS usually
        // finds the front tile itself, but "usually" is not enough here.
        // **Initial focus belongs on the main button, not on an episode.** This used
        // to say the opposite, because the header had nothing focusable after the
        // rebuild; that no longer holds now that the button row is back. As on the
        // movie page, focus lands there, and the button rule defines what the button does: the
        // episode where playback continues.
        // `episodeFront` stays: it decides which episode sits **at the front** of the
        // row. That is scroll position, not focus; the two had been confused.
        .defaultFocus($atPrimaryButton, true, priority: .userInitiated)
        .onChange(of: moreOpen) { _, opened in if !opened { atMoreButton = true } }
        .onChange(of: atPrimaryButton) { _, an in if an { lastFocus = .primaryButton } }
        .onChange(of: atMoreButton) { _, an in if an { lastFocus = .moreButton } }
        .onChange(of: atSeason) { _, now in if let now { lastFocus = .season(now) } }
        .onChange(of: atEpisode) { _, now in if let now { lastFocus = .episode(now) } }
        // See `lastFocus`: the player leaves the same empty focus as an open
        // panel, one level higher; the same assignment restores it.
        .onChange(of: play.wrappedValue == nil) { before, closed in
            guard closed, before == false else { return }
            focusBack()
        }
        // **Same after "Gemeinsam schauen".** The panel sits above everything in the
        // frame and locks the page like the player. If it closes without a player
        // opening, focus returns to its trigger.
        .onChange(of: SharedModel.shared.createFor == nil) { before, toward in
            guard toward, before == false, play.wrappedValue == nil else { return }
            focusBack()
        }
        .task {
            // Set focus first, then fade in: a button at opacity 0 is no focus target
            // on tvOS, and the initial focus would be lost.
            atPrimaryButton = true
            withAnimation(Theme.motion(.easeOut(duration: 0.3))) { inFade = true }
            await load()
        }
        // **`load()` also fetches the first season's episodes**, not a separate
        // `.task(id:)`. That ran alongside: the season header showed first and the
        // episodes jerked in after. Later changes are loaded by the season row
        // itself; see `seasonSelect`.
        // **Reload after the player.** It is a layer above this page, which never
        // disappears, and the `.task` above does not run twice, so progress and
        // "watched" would keep their pre-playback state. See
        // `AppModel.playbackEnded`.
        .onChange(of: model.pagesRefresh) { _, _ in Task { await refresh() } }
    }

    // MARK: Header

    /// **Header as on the movie page: text and button row.**
    /// "Continue · S2 E4", "From start", "Watchlist" and "Watched" sit in the
    /// header, in the same order on every platform with one main button per page
    ///. It turns white through focus, not a
    /// custom style: `ThemedButtonStyle` paints the focused pill white and focus lands
    /// on the row's first button on opening. Focus is white, as everywhere
    /// here.
    private var header: some View {
        DetailHeader(model: model, item: current, plan: plan) {
            // **Instant applies only to what was already there.**
            // Title, details, description, image and background were already on the home
            // page: they appear at once and do not move. The button row was not, so it
            // may fade in when it has something to say.
            // **The main button is exempt, for two reasons.** Faded in, it looked wrong:
            // the animation hung on the value, so the pill visibly grew from "Laedt…" to
            // "Fortsetzen S1 • E3", a slide to the right instead of a fade. And at
            // opacity 0 it is no focus target on tvOS, so the initial focus was lost.
            // It must therefore be right from the start. On the usual path it is:
            // coming in via an episode brings exactly the episode where playback
            // continues; see `startEpisodeValue`.
            HStack(spacing: 24) {
                Button { launch(nextWith) } label: {
                    // **Without a state, reserve the width including the episode** so the pill
                    // does not jump when it appears: the hidden placeholder "Abspielen S00 • F00"
                    // sets the width, the word sits at its left.
                    ZStack(alignment: .leading) {
                        if !statePresent {
                            Label(String(localized: "Abspielen \("S00 • F00")"),
                                  systemImage: "play.fill")
                                .hidden()
                                .accessibilityHidden(true)
                        }
                        Label(primaryButtonText, systemImage: "play.fill")
                    }
                    .transaction { $0.animation = nil }
                }
                .buttonStyle(ThemedButtonStyle())
                // **Do not disable while loading.**
                // A disabled button is no focus target on tvOS. Coming from search, the main
                // button was disabled while the episodes were still in flight (`nextWith`
                // still nil), so the focus engine took the next one in the row, Watchlist.
                // When the episode arrived the button became focusable again, but focus does
                // not move back by itself. The usual paths hid this because there the
                // episode is already cached. The same cause as the opacity 0 case above.
                // `seriesButton` already has the right label for this moment, "Laedt…"; it
                // was never shown because disabling made the button unreachable. Now it
                // shows, the button is focusable from the start, and `starte` does nothing
                // without an episode anyway. It stays disabled when there is truly nothing
                // ("Keine Folgen") and during `prepares`, the short moment after the
                // press.
                .disabled(prepares || (nextWith == nil && statePresent && !loadsEpisodes))
                .focused($atPrimaryButton)
                // Long press: the series' tile menu, as on its tile (``TileMenu``).
                .tileMenu(current, model: model)

                // Only when there is something to continue; otherwise "Von vorn" would mean
                // the same as the button next to it.
                if begun {
                    Button { launch(nextWith, since: 0) } label: {
                        Image(systemName: "arrow.counterclockwise").font(Theme.button)
                    }
                    .buttonStyle(ThemedButtonStyle(onlySymbol: true))
                    .accessibilityLabel(Text("Von vorn"))
                    .disabled(prepares)
                }

                StateButtons(model: model, item: current,
                                remembered: $remembered, watched: $watched,
                                message: $message)

                MoreButton(opened: $moreOpen)
                    .focused($atMoreButton)
                    .panelTrigger("mehr")
            }
            .opacity(inFade ? 1 : 0)
        }
    }

    /// Whether the episode where playback continues is already started.
    private var begun: Bool {
        (nextWith?.userData?.playbackPositionTicks ?? 0) > 0
    }

    /// "Fortsetzen S1 • E3", from `Titelangaben`, shared by all platforms. Lifted
    /// into `Item.seriesButton(episode:loads:)` after iOS, before it became a third
    /// copy (shared logic first in iOS, then adopted).
    private var primaryButtonText: String {
        // No state yet: neutral, without an episode. The episode joins with the
        // state in the fade of `load()`.
        guard statePresent else { return String(localized: "Abspielen") }
        return Item.seriesButton(episode: nextWith, loads: loadsEpisodes)
    }

    // MARK: Episodes

    @ViewBuilder
    private var episodesStrip: some View {
        // **A stack, so both share the same place.**
        // During the crossfade the old and new rows are **both** in the layout.
        // Stacked vertically, the new one would sit below the old and only slide up
        // once the old is gone. In the `ZStack` they overlap. The fixed height
        // holds the place even when nothing is shown; otherwise the page would
        // contract during the change.
        ZStack(alignment: .topLeading) {
            if loadsEpisodes {
                // Only so the page does not shrink while nothing is shown; the strip brings
                // its own height.
                Color.clear
                    .frame(height: Theme.landscapeHeight + 2 * Theme.railsPadding + 80)
            } else if episodesDisturbed {
                DisturbState(model: model, retry: { Task { await episodesLoad() } })
                    .frame(height: Theme.landscapeHeight + 2 * Theme.railsPadding + 80)
            } else if episodes.isEmpty {
                // **A way out, not a dead end.** Without a button the user is stuck, which
                // is worse with a remote than with a finger.
                EmptyState(symbol: "rectangle.stack",
                            title: "Keine Folgen in dieser Staffel",
                            button: ("Erneut versuchen", { Task { await episodesLoad() } }))
                    .frame(height: Theme.landscapeHeight + 2 * Theme.railsPadding + 80)
            } else {
                EpisodesStrip(model: model, episodes: episodes,
                               nextWith: episodeFront, atEpisode: $atEpisode) { episode in
                    launch(episode)
                }
                // Not on every page state change; see `EpisodesStrip.==`.
                .equatable()
                .id(episodes.first?.id ?? "leer")
                .transition(.opacity)
            }
        }
        // **No forced height.** It was meant against stacking during the crossfade
        // but caused the difference itself: the horizontal strip is greedy, fills a
        // given height, and centers its content. The content height depends on
        // state, so it sat differently per season: centered (32 pt off), then at the
        // top (season 1 too high), both symptoms of the same addition. The stack
        // alone suffices: it overlaps old and new rows and takes its height from
        // the content.
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Which episode sits at the front.
    /// Only if `nextWith` is **in the shown season**. Otherwise it would be the
    /// wrong row: after a season change the user wants E1, not an episode from a
    /// season that is not shown.
    private var episodeFront: String? {
        guard let state = nextWith,
              state.seasonId == selectedSeason?.id,
              episodes.contains(where: { $0.id == state.id })
        else { return nil }
        return state.id
    }

    /// **The seasons as a horizontal row of chips, not a panel under a pill.**
    ///
    /// A panel has the height of the screen and no more: with ten seasons the rows below
    /// the picture edge could not be reached. Width is what the TV has, and left and right
    /// is how the remote moves along a row anyway, so every season is one press away and
    /// the row scrolls where it does not fit.
    ///
    /// `ChipStyle` because it is the one chip that shows a selection: the selected season
    /// carries the accent, the others the calm surface, and focus is the usual lift.
    ///
    /// **Entering the row lands on the selected season**, not on the first or the one
    /// geometrically below: `.userInitiated` because exactly the press into the row is
    /// meant, as on the episode strip. The row is a `focusSection`, so down leaves it for
    /// the episodes and up for the button row.
    ///
    /// Only with two or more seasons: with one there is nothing to choose.
    @ViewBuilder
    private var seasonRow: some View {
        if seasons.count > 1 {
            ScrollView(.horizontal) {
                HStack(spacing: Theme.chipSpacing) {
                    ForEach(seasons) { season in
                        Button { seasonSelect(season) } label: {
                            Text(verbatim: season.name)
                                .lineLimit(1)
                        }
                        .buttonStyle(ChipStyle(an: selectedSeason?.id == season.id))
                        .focused($atSeason, equals: season.id)
                    }
                }
                // Inside the scroll surface so the focused chip grows without being clipped.
                .padding(.vertical, Theme.railsPadding)
                .scrollTargetLayout()
            }
            // **The selected season in view on opening.** Coming in via an episode of a late
            // season, its chip would otherwise sit beyond the right edge. A change of the
            // binding scrolls, an initial value does not; see `EpisodesStrip.ahead`. Not
            // while the user is in the row: there focus decides what is visible.
            .scrollPosition(id: $seasonFront, anchor: .center)
            .onChange(of: selectedSeason?.id, initial: true) { _, now in
                if atSeason == nil { seasonFront = now }
            }
            .contentMargins(.horizontal, Theme.edgePage, for: .scrollContent)
            .leadingEdgeFade()
            .scrollIndicators(.hidden)
            .focusSection()
            .defaultFocus($atSeason, selectedSeason?.id, priority: .userInitiated)
        }
    }

    /// Selecting a season counts as the user's choice and loads its episodes; see
    /// `seasonSelfSelected`.
    private func seasonSelect(_ season: Item) {
        guard selectedSeason?.id != season.id else { return }
        seasonSelfSelected = true
        selectedSeason = season
        Task { await episodesLoad() }
    }

    // MARK: Labels and loading

    /// **One fade-in, not five.** As on the iPhone (`SeriesDetailView`): series,
    /// state, seasons, similar and the selected season's episodes arrive together
    /// in the same transaction. Before, each answer was set separately, the
    /// season triggered its own `.task(id:)` for episodes, and "Ähnliches" came
    /// last with its own fade. The plan runs alongside and fades in within
    /// `DetailHeader`, which ties its fade to the plan itself.
    private func load() async {
        loadRun += 1
        let myOwn = loadRun
        async let freshSeries = model.item(id: series.id)
        async let list = model.seasons(series)
        async let state = model.stateInSeries(series)
        async let alike = model.similar(series)
        async let extra = model.extras(series)

        let addedSeries = await freshSeries
        // **`nil` means failed.** Writing an empty list into the `SeriesCache`
        // would cache a network error, and the next view would take it for truth.
        let fetchedSeasons = await list
        let seasonsNow = fetchedSeasons ?? seasons
        let newState = await state

        // Came via an episode: its season goes first. Otherwise the one where
        // playback continues, and only then the first (the next-episode rule, package). The old copy
        // checked the state's id before the episode number; without `SeasonId` the
        // running season showed. On refresh only a season the user picked stays; the
        // cached one is chosen again with the fresh state; see
        // `seasonSelfSelected`.
        let choice = (seasonSelfSelected ? selectedSeason : nil)
            ?? SeasonSelectionRule.choose(from: seasonsNow,
                                       hintID: startSeasonID ?? startEpisodeValue?.seasonId,
                                       hintNumber: startEpisodeValue?.parentIndexNumber,
                                       state: newState)
        async let p = fetchPlan(newState?.id)
        // Without seasons, all episodes of the series belong in the list, as on the
        // iPhone where `season: nil` stands for this.
        let fetch = choice != nil || (fetchedSeasons?.isEmpty ?? false)
        let fetchedEpisodes = fetch ? await model.episodes(series: series.id, season: choice?.id) : nil
        let newSimilar = await alike
        let newExtras = await extra
        // A newer run has started: its state wins.
        guard myOwn == loadRun else { return }

        // **The state applies without motion.** Arriving late, the button said
        // "Abspielen"; the episode now joins without the pill growing or neighbors
        // sliding (a soft fade-in looked odd).
        var immediate = Transaction()
        immediate.disablesAnimations = true
        withTransaction(immediate) {
            nextWith = newState
            statePresent = true
        }
        SeriesCache.shared.nextRemember(newState, for: series.id)
        withAnimation(Theme.motion(.easeOut(duration: 0.3))) {
            if let addedSeries { freshValue = addedSeries }
            if let fetchedSeasons { seasons = fetchedSeasons }
            similarDisturbed = newSimilar == nil
            if let newSimilar { similar = ListRules.withoutDouble(newSimilar) }
            if let newExtras { extras = ListRules.withoutDouble(newExtras) }
            // If the user picked a season meanwhile, the list belongs to that choice,
            // not this response.
            if !seasonSelfSelected || selectedSeason?.id == choice?.id {
                selectedSeason = choice
                if fetch {
                    episodesAccept(fetchedEpisodes, season: choice)
                } else {
                    loadsEpisodes = false
                }
            }
        }
        if fetchedSeasons != nil {
            SeriesCache.shared.remember(series.id) {
                $0.series = freshValue ?? series
                $0.seasons = seasons
                $0.nextWith = nextWith
            }
        }
        remembered = current.userData?.isFavorite ?? false
        watched = current.userData?.played ?? false
        if newState != nil {
            let newPlan = await p
            if myOwn == loadRun { plan = newPlan }
        }
    }

    private func fetchPlan(_ episodeID: String?) async -> PlaybackPlan? {
        guard let episodeID else { return nil }
        return await model.plan(for: episodeID)
    }

    private func similarLoad() async {
        let newSimilar = await model.similar(series)
        withAnimation(Theme.motion(.easeOut(duration: 0.3))) {
            similarDisturbed = newSimilar == nil
            if let newSimilar { similar = ListRules.withoutDouble(newSimilar) }
        }
    }

    /// The selected season's episodes, on season change and "Erneut versuchen".
    /// On opening, `load()` fetches them.
    private func episodesLoad() async {
        guard let season = selectedSeason else {
            loadsEpisodes = false
            return
        }
        if episodes.isEmpty { loadsEpisodes = true }
        let answer = await model.episodes(series: series.id, season: season.id)
        // A different season was picked meanwhile: its fetch wins. The `.task(id:)`
        // cancelled the old fetch; a `Task` does not.
        guard selectedSeason?.id == season.id else { return }

        // One move, one curve. Driving the change by hand (fade out, wait, swap,
        // fade in) was wrong: it flickered because the view was swapped under it.
        // See the id on the strip.
        withAnimation(Theme.motion(.easeInOut(duration: 0.28))) {
            episodesAccept(answer, season: season)
        }
    }

    private func episodesAccept(_ answer: [Item]?, season: Item?) {
        episodesDisturbed = answer == nil
        loadsEpisodes = false
        guard let fetched = answer else { return }
        episodes = fetched
        if let season {
            SeriesCache.shared.remember(series.id) { $0.episodes[season.id] = fetched }
        }
    }

    /// Back to the button or episode where the user last stood.
    private func focusBack() {
        switch lastFocus {
        case .primaryButton: atPrimaryButton = true
        case .moreButton: atMoreButton = true
        case .season(let id):
            if seasons.contains(where: { $0.id == id }) { atSeason = id }
            else { atPrimaryButton = true }
        case .episode(let id):
            // The episode may have left the list (other season): then to the front
            // episode, otherwise the main button.
            if episodes.contains(where: { $0.id == id }) { atEpisode = id }
            else if let front = episodeFront { atEpisode = front }
            else { atPrimaryButton = true }
        }
    }

    private var moreActions: [TitleAction] {
        // Watched sits first, as on the movie page, one level deeper than the
        // button row. See `TitleAction.watchState`.
        [TitleAction.watchState(current, model: model, watched: $watched,
                                 report: { message = $0 })]
        + TitleActions.forSeries(current, state: nextWith, season: selectedSeason,
                                  model: model,
                                  episodeStart: { episodeStart($0, since: $1) },
                                  report: { message = $0 },
                                  gemeinsam: SharedModel.shared.mayCreate
                                      ? { SharedModel.shared.createFor = $0 } : nil)
    }

    private func episodeStart(_ episode: Item, since: Double) {
        Task {
            guard let plan = await model.plan(for: episode.id) else {
                message = String(localized: "Die Folge konnte nicht geladen werden.")
                return
            }
            play.wrappedValue = PlayRequest(item: episode, plan: plan, startAt: since)
        }
    }

    /// **Reload everything, not just the series.**
    /// The first attempt fetched title and episodes but not `nextWith`. After
    /// "mark season watched" the main button would still offer to continue the
    /// third episode though the server counts it watched, and the plan would
    /// show the old episode. So it goes through `load()`: what is fetched on
    /// opening must be fetched on refresh, or the two paths diverge. The picked
    /// season stays; `load()` fetches its episodes itself.
    private func refresh() async {
        await load()
    }

    /// `since` overrides the remembered position; that is "From start".
    /// Without it the position rule applies: an episode starts at **its own** position.
    private func launch(_ episode: Item?, since: Double? = nil) {
        guard let episode else { return }
        PlayRequest.start(episode, since: since, freshValue: true, model: model, prepares: $prepares,
                              missing: { message = String(localized: "Der Server hat keine Datei zu dieser Folge.") },
                              play: { play.wrappedValue = $0 })
    }
}

/// Focus on a row: a calm surface in the player's layers. Unlike tiles,
/// where only size speaks, a row is no image and cannot get brighter. Same
/// surface as a resting chip.
struct EpisodesStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ContentBody(configuration: configuration)
    }

    private struct ContentBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focus

        var body: some View {
            configuration.label
                .foregroundStyle(Theme.font)
                .background(focus ? Color.white.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: Theme.cornerTile, style: .continuous))
                .animation(Theme.focusAnimation, value: focus)
        }
    }
}
