import JellyfinKit
import OSLog
import SwiftUI

/// The series page.
///
/// Its core is the one big button: it knows where you are. Jellyfin's NextUp
/// answers both cases in one call: the episode in progress, or the next
/// unwatched one if none is open.
struct SeriesDetailView: View {
    let model: AppModel
    let series: Item
    /// Coming from an episode, that episode's season is preselected.
    var startSeasonID: String? = nil
    /// The season **number** of the episode we came from.
    ///
    /// **Because the ID can be missing.** Some servers return no `SeasonId` on an
    /// episode, neither in the list entry nor in a single fetch, neither via
    /// `Shows/NextUp` nor elsewhere. Both ID comparisons then miss and the choice
    /// falls back to `seasons.first`: the button said "Play S6 E1" while season 5
    /// was shown below.
    ///
    /// The number is always present: `parentIndexNumber` on the episode,
    /// `indexNumber` on the season. It is the more reliable route, so it is an
    /// equal-ranking step, not a fallback.
    var startSeasonNumber: Int? = nil

    /// **Whatever is cached shows immediately**, otherwise there is an empty pass,
    /// and that is what the user sees.
    ///
    /// `SeriesCache` is shared but was not used on iPhone and iPad, so the page
    /// waited for the server on **every** open. On the Mac that was a measured 92 to
    /// 174 ms of blank page, and filling in later comes too late.
    ///
    /// **A deliberate difference from the Mac version.** It always picks a season
    /// from the cache, the first if necessary. Without a hint, `load()` knows a
    /// better way: the season the user is currently in (`state?.seasonId`). So the
    /// choice is only brought forward when a hint came along; otherwise the season
    /// list shows immediately and only the selection lands a moment later. The empty
    /// pass is gone either way.
    @MainActor init(model: AppModel, series: Item,
                    startSeasonID: String? = nil, startSeasonNumber: Int? = nil) {
        self.model = model
        self.series = series
        self.startSeasonID = startSeasonID
        self.startSeasonNumber = startSeasonNumber

        let remembered = SeriesCache.shared.state(series.id, with: model)
        let seasons = remembered?.seasons ?? []
        _seasons = State(initialValue: seasons)

        let hint = startSeasonID != nil || startSeasonNumber != nil
        // With a hint, the season brought along; otherwise the one the page was on at
        // the last visit.
        let season = hint
            ? seasons.first { $0.id == startSeasonID }
                ?? seasons.first { $0.indexNumber != nil
                                    && $0.indexNumber == startSeasonNumber }
            : seasons.first { $0.id == remembered?.selectedSeason }
        // Only with a cached episode is the progress state shown too; the plan belongs
        // to exactly that episode (`stateForget` clears both).
        _state = State(initialValue: remembered?.nextWith)
        _stateResolved = State(initialValue: remembered?.nextWith != nil)
        _plan = State(initialValue: remembered?.nextWith != nil ? remembered?.plan : nil)
        _planPresent = State(initialValue: remembered?.nextWith != nil && remembered?.plan != nil)
        _selectedSeason = State(initialValue: season)

        let episodes = season.flatMap { remembered?.episodes[$0.id] } ?? []
        _episodes = State(initialValue: episodes)
        _loads = State(initialValue: episodes.isEmpty)
        // Without cached episodes the placeholders show from the first frame, not only
        // once the episode fetch starts.
        _episodesLoads = State(initialValue: episodes.isEmpty)
        _remembered = State(initialValue: series.userData?.isFavorite ?? false)
        _watched = State(initialValue: series.userData?.played ?? false)
    }

    @Environment(\.dismiss) private var back
    @Environment(\.wide) private var wide
    @Environment(\.broad) private var broad
    @Environment(\.watchlistShown) private var watchlistShown
    @Environment(\.displayScale) private var pixelMetric
    /// For the header image that goes along with a download.
    @State private var pagesWidth: CGFloat = 0

    /// How far the page has scrolled; the header fades in based on it.
    /// See `ItemDetailView.distance`: as `@State`, every scroll step rebuilt the page.
    @State private var distance = ScrollDistance()

    @State private var state: Item?
    /// **Whether the next episode has been resolved**, even if there is none. The
    /// cache brings seasons and episodes but not the progress state; with cached
    /// episodes `loads` was already done at the start, and the button said "No
    /// episodes" for a second until the state arrived. Until then it now says
    /// "Loading…".
    @State private var stateResolved: Bool
    /// The plan is answered, with or without a result. See `proofRow`.
    @State private var planPresent: Bool
    @State private var seasons: [Item] = []
    /// **Three states, not two.** `[]` means "the series has no seasons", this flag
    /// means "the server did not answer". Both used to look the same, and the page
    /// claimed there was nothing on every network error.
    @State private var seasonsDisturbed = false
    @State private var selectedSeason: Item?
    @State private var episodes: [Item] = []
    /// The episode list had no loading, empty or failure branch: an empty season, a
    /// failed fetch and a running fetch all looked the same.
    /// Initial value is set in `init`.
    @State private var episodesLoads: Bool
    /// How many rows the list shows; with 500 episodes not all at once.
    @State private var episodesCount = EpisodesSection.step
    @State private var episodesDisturbed = false
    @State private var loadSheet = false
    @State private var loadItem: [DownloadItem] = []
    /// The step **before** the load sheet: what should be loaded?
    @State private var selectionOpen = false
    @State private var loadTitle = ""
    @State private var similar: [Item] = []
    @State private var similarDisturbed = false
    /// Extras of the series (specials, behind the scenes…). Empty: no tab.
    @State private var extras: [Item] = []
    /// Similar titles arrive after the rest of the page; until then placeholders
    /// instead of "Nothing similar found.".
    @State private var similarLoads = true
    @State private var loads = true
    @State private var play: PlayRequest?
    @State private var moreOpen = false
    @State private var message: String?
    @State private var prepares = false
    /// From `series.userData` in `init`; see `ItemDetailView`.
    @State private var remembered: Bool
    @State private var watched: Bool
    @State private var plan: PlaybackPlan?
    @State private var tab = 0
    /// Width of the grid under "Similar", from which the column count is derived,
    /// as in Library, Search and Watchlist.
    @State private var gridWidth: CGFloat = 0
    /// Has the user picked a season themselves? Then nothing overrides it anymore.
    @State private var selfSelected = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.reason.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // The same header as on the movie page, as its own building block so it is not
                    // written twice.
                    if wide {
                        HeroHeader(image: model.headerImageURL(for: series),
                                 poster: model.imageURL(for: series, maxHeight: 600,
                                                        portrait: true),
                                 title: series.name, logo: model.logoURL(for: series),
                                 secondaryLine: secondaryLine,
                                 progress: series.userData?.playedPercentage
                                     .map { $0 / 100 }) {
                            VStack(alignment: .leading, spacing: 14) {
                                proofRow
                                // Side by side only when there is room.
                                // In portrait the text block is 476 pt wide; the row needs about 620, and
                                // SwiftUI would then set the labels vertically.
                                if broad {
                                    HStack(alignment: .center, spacing: 14) {
                                        primaryButton
                                        actionRail
                                    }
                                } else {
                                    primaryButton
                                    actionRail
                                }
                            }
                        }
                        description
                            .frame(maxWidth: Theme.readWidth, alignment: .leading)
                            .padding(.horizontal, Theme.edgePageWide)
                            .padding(.top, 18)
                            .padding(.bottom, 22)
                    } else {
                    hero
                    VStack(alignment: .leading, spacing: 14) {
                        // Above the button, directly under the name.
                        proofRow
                        // **Button and row are one block, so they sit closer.** The spacing was 14, as
                        // large as to everything else, but horizontally the row's fields are only 8
                        // apart. The gap above was then larger than the gap between fields, and the row
                        // read as a separate thing instead of a continuation of the button.
                        VStack(alignment: .leading, spacing: 8) {
                            primaryButton
                            actionRail
                        }
                            // The row has its labels close under the circles; without extra padding they
                            // almost touch the text below.
                            .padding(.bottom, 8)
                        description
                    }
                    .padding(.horizontal, Theme.margin(wide: wide))
                    .padding(.top, 14)
                    .padding(.bottom, 22)
                    }

                    PageTab(title: extras.isEmpty ? ["Folgen", "Besetzung", "Ähnliches"]
                                                 : ["Folgen", "Besetzung", "Ähnliches", "Extras"],
                           selected: $tab)

                    switch tab {
                    case 0: episodesSection
                    case 1: cast
                    case 3 where !extras.isEmpty: extrasSection
                    default: similarSection
                    }
                }
                // **Never wider than the screen.** If a child gets wider, the whole page does,
                // and a page wider than its scroll area can be dragged sideways.
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                // **The color of the header image beneath the page** (experiment
                // `experiment-glas`), narrow and wide. When wide, `HeroHeader` carries its image
                // as the background and fades it via `onImageTint` with a mask instead of
                // `reason`; underneath lies the same mesh, computed from its minimum height
                // (iPad).
                .background(alignment: .top) {
                    MoodReason(url: model.headerImageURL(for: series),
                                   since: wide ? Theme.heroHeightWide : Theme.heroHeightValue)
                }
                // Translucent instead of solid surfaces on top; see `Theme.flaecheDurchsichtig`.
                .environment(\.onImageTint, true)
                .environment(\.imageColorSource, model.headerImageURL(for: series))
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(.named("blatt"))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pagesWidth = $0 }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, new in
                distance.setDown(new)
            }
            .ignoresSafeArea(edges: .top)

            // The same header as on the movie page. The old gradient with a free-standing
            // arrow used to be here, which is why no bar ever faded in on the series page.
            // The sheet hangs on an empty surface; without the `if`, wide windows would get
            // two paths to the same actions.
            if !wide {
                ActionSheet(opened: $moreOpen, title: sheetTitle,
                               actions: moreActions)
                    .zIndex(20)
            }
            // **The sheet is always in the tree, even when empty.**
            //
            // It used to hang on `if !loadItem.isEmpty`, and on the **first** open the
            // items and `opened` were set in the same pass. The view was created at the
            // moment it should already be open: there was no closed state to slide in from.
            // The window appeared abruptly with its title in place; from the second time it
            // animated because the view already existed.
            //
            // `LoadSheet` handles empty items fine: `bytes` is then 0, and closed it draws
            // nothing anyway.
            LoadSheet(opened: $loadSheet, model: model, entries: loadItem,
                      title: loadTitle, images: loadImages,
                      failed: { message = $0 })
                .zIndex(20)
            // **The selection sits in front of the load sheet, not beside it.** It only
            // collects episodes; space, Wi-Fi and size are still computed by `LoadSheet`.
            LoadSelection(opened: $selectionOpen, model: model, series: series,
                        seasons: seasons,
                        preloaded: selectedSeason.map { [$0.id: episodes] } ?? [:]) { selected, quality in
                let newOne = selected.compactMap { entries($0)?.inQuality(quality) }
                guard !newOne.isEmpty else { return }
                sheetShow(newOne, title: series.name)
            }
            .zIndex(20)
            if let message {
                HintStrip(text: message) { self.message = nil }
                    .zIndex(21)
            }

            DetailHeaderReader(title: series.name, distance: distance) { back() }
        }
        .animation(Theme.sectionSwitch, value: tab)
        // When wide, the panel hangs on the button instead of the bottom edge of the
        // screen. The anchor comes from `asActionAnchor()`; fixed coordinates would
        // not work because the button row moves with the label length.
        .overlayPreferenceValue(ActionAnchor.self) { anchor in
            GeometryReader { space in
                if wide, moreOpen, let anchor {
                    ActionPanel(opened: $moreOpen, title: sheetTitle,
                                   actions: moreActions,
                                   anchor: space[anchor], space: space.size)
                }
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
        .task { await load() }
        // **Refetch after the player**, and only once the end report has gone through;
        // see `AppModel.playbackEnded`. Otherwise progress and "watched" would stay
        // at their pre-playback state.
        .catchUp(at: model.pagesRefresh) {
            Task { await load(postPlayback: true) }
        }
        // **The season brought along can arrive late.**
        //
        // `SeasonTarget` refetches the episode because the list entry can carry an old
        // season: when someone finishes a season and adds the next, the tile still shows
        // the old one. That answer only arrives once the page is up and `load()` has
        // made its choice. Without this line the refetch had no effect: "Play S6E1"
        // above, season 5 below.
        .onChange(of: startSeasonID) { _, new in
            guard !selfSelected, let new,
                  let hit = seasons.first(where: { $0.id == new }),
                  hit.id != selectedSeason?.id else { return }
            seasonSwitch(hit)
        }
    }

    /// Fetch everything that can change.
    ///
    /// **One load function, not two.** There used to be a separate `auffrischen` that
    /// rebuilt part of this and forgot the plan. After "mark season as watched" the
    /// main button showed the new episode but carried the old plan, including a wrong
    /// Direct Play verdict. The same bug was found on tvOS: `auffrischen` stood in
    /// for "everything is fresh again" because it usually coincides with it. Usually.
    /// `postPlayback`: only progress state, series and the episodes of the chosen
    /// season. Seasons and similar titles do not change while watching; fetching them
    /// (and the episodes again afterwards) cost several requests after every player
    /// close, exactly when the end report runs.
    private func load(postPlayback: Bool = false) async {
        async let a = model.stateInSeries(series)
        async let b = postPlayback ? nil : seasonsFetch()
        async let c = postPlayback ? nil : similarFetch()
        async let e = postPlayback ? nil : model.extras(series)
        // **The series itself, fresh.** Remembered and watched came from the entry the
        // page was opened with, and that never changes. After "mark series as watched"
        // the page reloaded, read the old entry again, and the button fell back to "not
        // watched"; a second tap marked everything again instead of resetting it. TV and
        // Mac always fetch the series fresh here.
        async let d = model.item(id: series.id)
        // Remove duplicate IDs; see `ItemDetailView`.
        //
        // **`nil` is not an empty list.** If the server stays silent, the page keeps
        // what it had and records the failure. Before, the same case set both lists to
        // empty, the season picker vanished and below it stood "Nothing similar found".
        // **Similar titles do not block.** That fetch is the slowest on large servers;
        // state and seasons are enough for the episode list, similar titles come last.
        let (freshState, freshSeasons) = await (a, b)
        let seasonsNow = freshSeasons ?? seasons
        // Coming from an episode, its season; otherwise the one visited last. On a
        // refresh the choice already made stays.
        // The chain lives in the package: first the hint (ID, then number), then the
        // progress state. The old local copy checked the state's ID before the hint's
        // number, so an episode without `SeasonId` showed the current season instead of
        // its own.
        let choice = selectedSeason
            ?? SeasonSelectionRule.choose(from: seasonsNow,
                                       hintID: startSeasonID,
                                       hintNumber: startSeasonNumber,
                                       state: freshState)

        // **One fade-in, not five.** Season choice, episodes, state and similar titles
        // arrive together in the same transaction. The page used to apply each answer
        // separately: first the season choice without episodes (briefly "No episodes in
        // this season"), then it waited for the plan, then placeholders, then the
        // episodes. The plan now runs alongside and fades in only the detail line, whose
        // space is already reserved.
        async let p = fetchPlan(freshState?.id)
        let fetched = await model.episodes(series: series.id, season: choice?.id)
        // Cancelled is not a failure: set nothing, the page keeps its state.
        if Task.isCancelled { return }
        withAnimation(Theme.reveal) {
            state = freshState
            if !postPlayback { seasonsDisturbed = freshSeasons == nil }
            seasons = seasonsNow
            stateResolved = true
            // If the user picked a season in the meantime, the list belongs to that choice,
            // not to this answer.
            if selectedSeason == nil || selectedSeason?.id == choice?.id {
                selectedSeason = choice
                episodesAccept(fetched)
            }
            loads = false
        }
        AppLog.writeOut("[Staffel] \(series.name): mitgebracht=\(startSeasonID ?? "-")/\(startSeasonNumber.map(String.init) ?? "-") "
            + "stand=\(state.map { "S\($0.parentIndexNumber ?? -1)E\($0.indexNumber ?? -1) " + ($0.seasonId ?? "-") } ?? "-") "
            + "gewaehlt=\(selectedSeason?.name ?? "-") "
            + "vorhanden=[\(seasons.map { "\($0.name)=\($0.id)" }.joined(separator: " "))]")
        // For the next visit to the same series, and for the route from an episode,
        // which would otherwise refetch the series every time.
        let current = await d ?? series
        SeriesCache.shared.remember(current)
        let selectedID = selectedSeason?.id
        SeriesCache.shared.remember(series.id) {
            $0.seasons = seasons
            $0.selectedSeason = selectedID
            if let freshState { $0.nextWith = freshState }
        }
        remembered = current.userData?.isFavorite ?? false
        watched = current.userData?.played ?? false
        // The plan without animation, only the fade-in with it: in the animated
        // transaction the new Direct Play badge visibly pushed rating and certification
        // to the right while the row slid in from the left.
        if freshState != nil {
            let freshPlan = await p
            plan = freshPlan
            SeriesCache.shared.remember(series.id) { $0.plan = freshPlan }
        }
        withAnimation(Theme.reveal) { planPresent = true }
        // Similar titles last: nothing above waits for them. `nil` is not an empty
        // list: the fetch did not run or failed.
        if !postPlayback {
            let freshSimilar = await c
            // Failed or none: then the tab does not exist.
            let freshExtras = await e
            if Task.isCancelled { return }
            withAnimation(Theme.reveal) {
                if let freshExtras { extras = ListRules.withoutDouble(freshExtras) }
                if extras.isEmpty && tab == 3 { tab = 0 }
                similarLoads = false
                similarDisturbed = freshSimilar == nil && similar.isEmpty
                if let freshSimilar { similar = ListRules.withoutDouble(freshSimilar) }
            }
        }
    }

    private func refresh() async { await load() }

    private func seasonsFetch() async -> [Item]? { await model.seasons(series) }
    private func similarFetch() async -> [Item]? { await model.similar(series) }

    private func fetchPlan(_ episodeID: String?) async -> PlaybackPlan? {
        guard let episodeID else { return nil }
        return await model.plan(for: episodeID, still: true)
    }

    // MARK: Parts

    private var hero: some View {
        HeroImage(url: model.headerImageURL(for: series))
            .overlay(alignment: .bottom) { HeroRunOut(image: model.headerImageURL(for: series)) }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    #if os(iOS)
                    TitleMark(title: series.name, logo: model.logoURL(for: series))
                    #else
                    Text(series.name)
                        .font(Theme.title)
                        .tracking(Theme.lockTitle)
                        .foregroundStyle(Theme.font)
                    #endif
                    Text(secondaryLine)
                        // Year, seasons and genre count as one entry: 12. It used to be 14, which
                        // appears in no step of the scale.
                        .font(Theme.small)
                        .foregroundStyle(Theme.fontQuiet)
                        .lineLimit(1)
                }
                .padding(.horizontal, Theme.margin(wide: wide))
                .padding(.bottom, 16)
            }
    }

    private var secondaryLine: String {
        var parts: [String] = []
        if let year = series.productionYear { parts.append(String(year)) }
        // Not `childCount`: that field means different things depending on the query and
        // read one for a series with nineteen seasons. Once the seasons are loaded we
        // count them ourselves.
        // If only one season is in the library, we say which. "1 season" next to a
        // button saying "S2 · E1" reads like a contradiction, when season 1 is simply
        // missing on disk.
        if seasons.count == 1, let only = seasons.first {
            parts.append(only.name)
        } else if let count = seasons.isEmpty ? series.childCount : seasons.count {
            parts.append(String(localized: "\(count) Staffeln"))
        }
        if let genres = series.genres, !genres.isEmpty {
            parts.append(genres.prefix(2).joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    /// **First with the plan, then as a whole.** Stars and age rating are there
    /// immediately, the Direct Play badge only with the playback plan, and then it
    /// pushed itself in front and the other two to the right. Now the row holds its
    /// place but stays invisible until the plan is there, then fades in all at once.
    /// If no plan comes, it fades in anyway, just without the badge.
    private var proofRow: some View {
        ProofRow(directPlayFlag: plan?.isLossless ?? false,
                   hint: plan.map { $0.isLossless ? nil : $0.method.rawValue } ?? nil,
                   rating: series.communityRating,
                   sharing: series.ageRating)
            // **Fixed height, even when empty.** The row only arrives with the plan, and
            // from the list often without rating and certification. Empty it had no height,
            // so the button below sat higher and dropped when it filled. Always as tall as
            // one badge.
            // `height`, not `minHeight`: the switch to scaling type turned it into a
            // minimum and invalidated the reasoning above; with a larger system font the row
            // would have grown past 26 and the button would have jumped exactly as described.
            // The row only carries badges, and badges stay fixed.
            .frame(height: 26, alignment: .leading)
            // **Fades in, does not move.** Nothing inside is animated: when a badge is
            // added the row is already complete; only the opacity underneath animates.
            .transaction { $0.animation = nil }
            .opacity(planPresent ? 1 : 0)
    }

    private var primaryButton: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                if let state { launch(state) }
            } label: {
                // **Empty until the episode is known, then the content fades in in place.**
                // Before, "Loading…" stood there and switched to the episode; the label got
                // wider and the icon moved left from the center. Now the whole content arrives
                // at once and nothing moves. The invisible placeholder keeps the height so the
                // button does not grow.
                ZStack {
                    Text(verbatim: " ").hidden()
                    if buttonReady {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill").font(.system(size: 15))
                                .opacity(prepares ? 0.5 : 1)
                            Text(buttonText)
                        }
                        .transition(.opacity)
                    }
                }
                .animation(Theme.reveal, value: buttonReady)
                .accessibilityLabel(Text(buttonText))
            }
            .buttonStyle(PrimaryButtonStyle(stretches: !wide))
            // Long press: the series' tile menu, as on its tile.
            .tileMenu(series, model: model)
            // **While loading it stays enabled and shows "Loading…".**
            //
            // On tvOS a disabled button is not a focus target: coming from Search, where
            // nothing is preloaded, the initial focus jumped to "Watchlist" and did not come
            // back when the episode arrived. The same pattern applies here, only without a
            // visible episode, since a finger finds its button itself. Kept identical so
            // the platforms do not drift apart again.
            //
            // A press while loading does nothing; `starte` has the `guard` anyway.
            .disabled(prepares || (state == nil && stateResolved && !loads))

            if let state, let rest = remainingTime(state) {
                // Remaining time counts as one entry: 12. It used to be 11; that step belongs
                // to uppercase group titles, not body text.
                Text(rest).growing(12).foregroundStyle(Theme.fontQuiet)
            }
            // When wide, the progress sits at the poster in the header; here it would be the
            // same thing twice, across the whole page.
            if !wide, let state, let share = state.userData?.playedPercentage,
               share > 0 {
                ProgressBar(share: share / 100)
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            }
        }
    }

    /// The same row as on the movie page: four icons with labels. Before there were
    /// two wide buttons, which made the two pages look different.
    private var actionRail: some View {
        HStack(spacing: 8) {
            if watchlistShown {
                ActionButton(symbol: remembered ? "bookmark.fill" : "bookmark",
                             title: "Merkliste", active: remembered, stretches: !broad) {
                    remembered.toggle()
                    Task {
                        if let reason = await model.setWatchlist(series, an: remembered) {
                            remembered.toggle()
                            message = reason
                        }
                    }
                }
            }
            // **Download is in the row, not in a hidden chip.**
            //
            // Download used to be scattered over three places, and the most prominent was a
            // round chip beside the season picker that nobody looks at. It now has a place
            // between Watchlist and Watched, as on Mac and TV. The trailer moves into the
            // More sheet: a trailer is something to play, not a permanent guest in a row of
            // four slots.
            //
            // With downloads off there is nothing to download and the trailer keeps its
            // place.
            if model.downloadButtonShow {
                ActionButton(symbol: "arrow.down", title: "Laden", stretches: !broad) {
                    // **Always the selection sheet, even with one season.**
                    //
                    // It used to depend on `seasons.count > 1`; with a single season it went
                    // straight to the load sheet and took the whole season. That was the gap:
                    // picking single episodes was impossible. A series always has episodes, so there
                    // is always something to choose.
                    selectionOpen = true
                }
            } else {
                ActionButton(symbol: "film", title: "Trailer", stretches: !broad) { trailerStart() }
            }
            ActionButton(symbol: watched ? "checkmark.circle.fill" : "checkmark.circle",
                         title: "Gesehen", active: watched, stretches: !broad) {
                watched.toggle()
                Task {
                    if let reason = await model.setWatched(series, an: watched) {
                        watched.toggle()
                        message = reason
                    }
                    // Refetching goes through `model.pagesRefresh`.
                }
            }
            ActionButton(symbol: "ellipsis", title: "Mehr", stretches: !broad) { moreOpen = true }
                .asActionAnchor()
        }
        // No own padding anymore: the four fields share the row and end where the button
        // above ends. The gaps that spread the circles across the width are gone.
    }

    @ViewBuilder
    private var description: some View {
        if let text = series.description {
            CollapsibleText(text: text)
        }
    }

    private var episodesSection: some View {
        // Full width, as on iPhone. The checkmark belongs at the right edge of the row;
        // squeezed into a reading width it stood mid-page and looked unconnected.
        episodesList
    }

    /// The seasons as a row of chips; see `SeasonChipRow`. Picking one counts as the
    /// user's choice, which nothing overrides afterwards.
    private var seasonRow: some View {
        SeasonChipRow(seasons: seasons, selected: selectedSeason?.id,
                      margin: Theme.margin(wide: wide)) { season in
            selfSelected = true
            seasonSwitch(season)
        }
    }

    @ViewBuilder
    private var episodesList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if seasonsDisturbed && seasons.isEmpty {
                // Without seasons there are no episodes: the failure belongs at the start of the
                // section, not under an empty season picker.
                DisturbHint(model: model) { Task { await load() } }
            } else if !seasons.isEmpty {
                // **Only from two seasons**, as on every platform: a single chip offers no
                // choice, and the episodes below already say which season they belong to.
                if seasons.count > 1 {
                    seasonRow
                        .padding(.vertical, 14)
                        .transition(.opacity)
                }
            } else if loads {
                // **Empty, but with space.** While the season row loads, its height stays
                // free (34, 14 above and below); it fades in at that spot.
                Color.clear.frame(height: 34 + 2 * 14)
            }

            // **Four branches where there was one.** If the fetch failed, the page says so;
            // while it runs the area stays empty; if the season really is empty, it says
            // that. Before, all three were the same blank area.
            if episodesDisturbed {
                DisturbHint(model: model) { Task { await episodesLoad() } }
            } else if episodesLoads && episodes.isEmpty {
                // **No placeholders.** The list is the last thing on the page, nothing below
                // jumps; the episodes fade in when they are there. Empty here only means
                // "loading", never "no episodes".
                EmptyView()
            } else if episodes.isEmpty && !seasons.isEmpty && !loads {
                // **No new wording.** "No episodes in this season" has long been in the catalog
                // (tvOS uses it); a second sentence for the same situation would be a second
                // entry that eventually sounds different in some language.
                emptyHint("Keine Folgen in dieser Staffel")
            } else {
            // Not lazy: each row is itself a scroll area since swiping was added, and nested
            // inside, a LazyVStack can no longer estimate its height; only the first row
            // remained. A season usually has around 25 episodes, which the plain stack
            // handles easily. For anime with 500 episodes it does not: hence
            // `EpisodesSection.schritt` first, more on request.
            VStack(spacing: 0) {
                ForEach(episodes.prefix(episodesCount)) { episode in
                    let actualValue = episode.userData?.played ?? false
                    SwipeRow(symbol: actualValue ? "arrow.uturn.backward" : "checkmark",
                               label: actualValue ? "Ungesehen" : "Gesehen",
                               action: { watchedToggle(episode) },
                               onTap: { launch(episode) }) {
                        // **No download ring per episode anymore.**
                        //
                        // It was one of three ways to download, and with the selection sheet it is the
                        // worst: a column at the right edge of every row, 26 pt, offering the same thing
                        // twenty-five times for twenty-five episodes. To get a single episode, tick it in
                        // the sheet, where its size is visible too.
                        EpisodesRow(model: model, episode: episode,
                                    // **Only in the player.** There the larger image says "this is playing"; on the
                                    // series page the big button at the top says it, and a row that stands out would
                                    // be a second statement.
                                    ongoing: false)
                    }
                    // **Long press: the tile menu**, as on every tile (``TileMenu``): play,
                    // watched/unwatched, download, watch together. Before, only "Watch together"
                    // was here.
                    .tileMenu(episode, model: model, landscape: true)
                    // **No divider anymore.** The still image already separates the rows; a hairline
                    // beside it says the same thing twice. Where the list does need a marker, on the
                    // running episode, it carries a surface, which lives in `EpisodesRow`.
                }
                if episodes.count > episodesCount {
                    MoreEpisodesButton {
                        withAnimation(Theme.reveal) {
                            episodesCount += EpisodesSection.step
                        }
                    }
                }
            }
            // **One season replaces the other, it does not blend with it.** Without its own
            // identity SwiftUI considered the rows the same and only swapped their content;
            // with it, the old list fades out and the new one in.
            .id(selectedSeason?.id)
            .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var cast: some View {
        let folks = (state?.actors.isEmpty == false ? state!.actors : series.actors)
        if folks.isEmpty && loads {
            // A series from the list often carries no cast; that arrives with the state.
            // Until then no "No cast", and **a row shaped like the tiles**, not one point of
            // height: otherwise the tab grew by a whole row on arrival.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 110), spacing: 14)],
                      spacing: 20) {
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
                      spacing: 20) {
                ForEach(folks) { person in
                    NavigationLink(value: PersonRoute(person: person, origin: series.name)) {
                        CastTile(image: model.personImage(person),
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
                ForEach(extras) { extra in
                    ExtraTile(model: model, extra: extra, prepares: $prepares,
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
        if similarDisturbed && similar.isEmpty {
            DisturbHint(model: model) { Task { await load() } }
        } else if similar.isEmpty && (loads || similarLoads) {
            // A row using the same column computation as the grid below.
            GridPlaceholder(columns: Theme.columns(usableNow: gridWidth - 2 * Theme.margin(wide: wide),
                                                    wide: wide),
                              rails: 1)
                .padding(.horizontal, Theme.margin(wide: wide))
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
                .padding(.top, 20)
        } else if similar.isEmpty {
            emptyHint("Nichts Ähnliches gefunden.")
        } else {
            // **The same column computation as Library and Search.** There was an adaptive
            // grid with a fixed minimum width per tile. On iPhone two fit side by side and a
            // gap remained on the right, while everywhere else three stand in the same
            // place. Reported by a tester.
            let usableNow = gridWidth - 2 * Theme.margin(wide: wide)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.tileSpacing),
                                     count: Theme.columns(usableNow: usableNow, wide: wide)),
                      alignment: .leading, spacing: 20) {
                ForEach(similar) { title in
                    NavigationLink(value: title) {
                        PosterTile(model: model, item: title, width: nil)
                    }
                    .buttonStyle(Theme.PressButton())
                }
            }
            .padding(.horizontal, Theme.margin(wide: wide))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
            .padding(.top, 20)
        }
    }

    /// **`LocalizedStringKey`, not `String`.** `Text(someString)` is verbatim: Xcode
    /// never extracts the text into the catalog and it stays German in every
    /// language. That is how "Keine Besetzung hinterlegt." appeared in the middle of
    /// an English page.
    private func emptyHint(_ text: LocalizedStringKey) -> some View {
        Text(text)
            // Empty states follow the system font.
            .growing(15)
            .foregroundStyle(Theme.fontVeryQuiet)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 40)
    }

    // MARK: Derived values

    /// The label is fixed: the episode is resolved and, if there is none, the season
    /// load is over too.
    private var buttonReady: Bool { stateResolved && (state != nil || !loads) }

    private var buttonText: String {
        Item.seriesButton(episode: state, loads: loads || !stateResolved)
    }

    private func remainingTime(_ episode: Item) -> String? { episode.remainingTimeText }


    private func episodesLoad() async {
        episodesLoads = true
        let of = selectedSeason?.id
        let fetched = await model.episodes(series: series.id, season: of)
        // Cancelled (page left, new run) is not a failure.
        if Task.isCancelled { return }
        // Whoever has picked another season in the meantime does not get the old
        // season's episodes under the new one's name.
        guard selectedSeason?.id == of else { return }
        withAnimation(Theme.reveal) { episodesAccept(fetched) }
    }

    /// **The old season's episodes go immediately.** They used to stay until the new
    /// answer arrived: "Season 3" on top, the second season's episodes below.
    /// Whatever is cached shows right away; otherwise the list is empty until the
    /// episodes arrive.
    private func seasonSwitch(_ season: Item) {
        let remembered = SeriesCache.shared.state(series.id, with: model)?.episodes[season.id]
        withAnimation(Theme.reveal) {
            selectedSeason = season
            episodes = remembered ?? []
            episodesCount = EpisodesSection.step
            episodesDisturbed = false
            episodesLoads = remembered == nil
        }
        SeriesCache.shared.remember(series.id) { $0.selectedSeason = season.id }
        Task { await episodesLoad() }
    }

    private func episodesAccept(_ fetched: [Item]?) {
        episodesLoads = false
        // Only an empty page shows the failure; if a list is already there it stays
        // (dead zone after the player, cancelled task).
        episodesDisturbed = fetched == nil && episodes.isEmpty
        // Failed: the old list stays and nothing goes into the cache; a cached network
        // error would be worse than none.
        guard let fetched else { return }
        episodes = fetched
        if let id = selectedSeason?.id {
            SeriesCache.shared.remember(series.id) { $0.episodes[id] = fetched }
        }
    }

    // MARK: Downloads

    /// A `DownloadItem` from an episode. **The same source the player would use**:
    /// it is the same file.
    private func entries(_ episode: Item) -> DownloadItem? {
        guard let account = model.session?.userID else { return nil }
        let source = episode.mediaSources?.first
        return DownloadItem(
            id: episode.id, account: account, art: .episode, title: episode.name,
            series: series.name, seriesIdentifier: series.id,
            season: episode.parentIndexNumber ?? selectedSeason?.indexNumber,
            episode: episode.indexNumber,
            runtimeTicks: episode.runTimeTicks, container: source?.container,
            source: source?.id, bytes: source?.size ?? 0,
            watchState: episode.userData, videoCodec: source?.videoCodec)
    }

    /// The series poster plus the landscape image of every episode being loaded, and
    /// the large header image for the series page in Downloads.
    ///
    /// **The header image at screen resolution.** `Heldbild` is 300 high and fills
    /// the width; a 16:9 image needs at least 533 pt of width for that, the full
    /// width on iPad. Multiplied by the scale so it is sharp on the device. The
    /// poster is 600 high instead of a tile's 300.
    private var loadImages: [String: URL] {
        var card: [String: URL] = [:]
        if let poster = model.imageURL(for: series, maxHeight: 600, portrait: true) {
            card[series.id] = poster
        }
        let points = max(pagesWidth, Theme.heroHeightValue * 16 / 9)
        if let header = model.headerImageURL(for: series, width: Int((points * pixelMetric).rounded(.up))) {
            card[DownloadManager.headerKey(series.id)] = header
        }
        for p in loadItem {
            if let f = episodes.first(where: { $0.id == p.id }),
               let image = model.imageURL(for: f, maxHeight: 220) {
                card[p.id] = image
            }
        }
        return card
    }

    /// **Set the content first, then show it, one pass later.**
    ///
    /// The sheet slides in by its measured height. If the content is set in the same
    /// pass in which `opened` flips, the **old** measurement still applies to the
    /// motion: the card moves, the texts in it change meanwhile and then just appear.
    /// The `Task` delays showing by one pass; in between the card is measured once
    /// with its new content, closed and invisible.
    ///
    /// Same spot, same solution as for the selection sheets.
    private func sheetShow(_ newOne: [DownloadItem], title: String) {
        loadItem = newOne
        loadTitle = title
        // **One sheet at a time.** If the call comes from the selection sheet, which is
        // sliding down, both at once would be two cards crossing. A moment's delay is
        // enough; the spring takes 0.35 s, and 0.26 s of that is seen as a handover, not
        // as waiting.
        Task { @MainActor in
            if selectionOpen { try? await Task.sleep(for: .milliseconds(260)) }
            loadSheet = true
        }
    }

    /// **Load a single episode, now via the selection sheet.**
    ///
    /// From a user report: an anime season has over a hundred episodes, and for a
    /// train ride two of them should come along. A whole season is the wrong order of
    /// magnitude.
    ///
    /// `Ladeauswahl` now covers this: tick the episodes and see their combined size.
    /// The ring on every row that did the same individually is gone; it offered the
    /// same thing twenty-five times for twenty-five episodes.

    private func launch(_ episode: Item) {
        guard !prepares else { return }
        // On press, not after the fetch: a haptic tick half a second later feels
        // unrelated.
        Theme.jerk(.medium)
        PlayRequest.start(episode, model: model, prepares: $prepares) { play = $0 }
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
            LoadField().frame(width: 116, height: 116 * 65 / 116)
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
                    // **Single line.** Two lines made the rows of a season end at different heights
                    // and pushed the detail below away; same decision as on the tile.
                    .lineLimit(1)

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
        .padding(.vertical, 12)
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

    private var watched: Bool { episode.userData?.played ?? false }
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
        EpisodesRowsLayout(title: Text("\(episode.indexNumber.map { "\($0). " } ?? "")\(episode.name)"),
                           secondaryLine: Text(secondaryLine),
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
        .accessibilityLabel(Text(verbatim: [
            episode.indexNumber.map { String(localized: "Folge \($0)") },
            episode.name,
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
    private var imageWidthValue: CGFloat { ongoing ? 134 : 116 }

    private var preview: some View {
        Picture(url: model.imageURL(for: episode, maxHeight: 220),
             width: imageWidthValue, height: imageWidthValue * 65 / 116, corner: Theme.cornerTile,
             // A full bar **and** a checkmark would be the same information twice.
             progress: watched ? nil
                                  : episode.userData?.playedPercentage.map { $0 / 100 })
            .watchedCheckmark(watched)
    }


    private var secondaryLine: String {
        // `runtimeSeconds` is 0, not nil, for an episode without a value; the rule in
        // the package catches both. This exact check was once missing on TV, and the
        // series showed "0 min.".
        guard DisplayRules.runtimeShow(seconds: episode.runtimeSeconds),
              let total = episode.runtimeSeconds else { return "" }
        // Runtime only: the file size is in the load selection, and on the episode it is
        // a number without a question behind it.
        return episode.remainingTimeText ?? "\(Int(total / 60)) min"
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
            SubpageHeader(title: season.name) { back() }
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

extension SeriesDetailView {
    /// Toggle an episode's watched state and refresh the list.
    func watchedToggle(_ episode: Item) {
        let new = !(episode.userData?.played ?? false)
        Task {
            if let reason = await model.setWatched(episode, an: new) {
                message = reason
                return
            }
            await episodesLoad()
        }
    }
}

extension SeriesDetailView {

    func trailerStart() {
        TrailerStart.start(series, model: model,
                             play: { play = $0 },
                             report: { message = $0 })
    }

    /// What the sheet works on: the episode in progress, otherwise the series.
    var sheetTitle: String {
        guard let state else { return series.name }
        if let st = state.parentIndexNumber, let fo = state.indexNumber {
            return "\(series.name) · S\(st) E\(fo)"
        }
        return series.name
    }

    var moreActions: [TitleAction] {
        var list = TitleActions.forSeries(series, state: state, season: selectedSeason,
                                              model: model,
                                              episodeStart: { episodeStart($0, since: $1) },
                                              report: { message = $0 },
                                              gemeinsam: SharedModel.shared.mayCreate
                                                  ? { SharedModel.shared.createFor = $0 } : nil)
        // The trailer, when Download has its place in the row. Not the other way round,
        // or it would appear twice.
        if model.downloadButtonShow {
            list.insert(.init(symbol: "film", text: "Trailer") { trailerStart() }, at: 0)
        }
        return list
    }

    private func episodeStart(_ episode: Item, since: Double) {
        Task {
            guard let wish = await model.episodesRequest(episode, since: since) else {
                message = AppModel.episodeNotLoaded
                return
            }
            play = wish
        }
    }
}
