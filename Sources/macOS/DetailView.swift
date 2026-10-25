import AppKit
import JellyfinKit
import SwiftUI

/// Detail page. Movies and series share the same header, as on iPhone; only the
/// content below it differs.
struct DetailView: View {
    let model: AppModel
    let item: Item
    let back: () -> Void

    @State private var full: Item?

    /// Show the full item as soon as it arrives.
    ///
    /// The list query only returns `Overview` and the aspect ratio. Description,
    /// rating, certification, genres and runtime used to appear all in the same frame,
    /// right after the transition finished, which reads as a sudden pop-in. The header
    /// has fixed slots, so nothing moves when a text arrives late.
    private var title: Item { full ?? item }

    var body: some View {
        Group {
            // Branch on `item.type`, not on `title.type`. The type is already known from the
            // list; branching on the fetched item could switch branches midway and throw
            // away and rebuild half the page.
            switch item.type {
            case "Series":
                SeriesView(model: model, series: title, back: back)
            case "Episode":
                // An episode has no page of its own. It would show nothing the episode list does
                // not already show. Fetch the series and show its page with the episode's season
                // preselected.
                SeasonTarget(model: model, episode: title, back: back)
            default:
                FilmView(model: model, film: title, back: back)
            }
        }
        // Only set once the page is ready: swapping rebuilds it completely (`InTravel`).
        .task {
            guard full == nil else { return }
            let fetched = await model.item(id: item.id)
            await InTravel.waitFor()
            guard !Task.isCancelled else { return }
            full = fetched
        }
        // Reload the title after the player closes. The player is an overlay above this
        // view, so `.task` does not run again. See `AppModel.playbackEnded`.
        .onChange(of: model.pagesRefresh) { _, _ in
            Task { if let new = await model.item(id: item.id) { full = new } }
        }
    }
}

/// Intermediate step from an episode to the series page.
struct SeasonTarget: View {
    let model: AppModel
    let episode: Item
    let back: () -> Void

    @State private var series: Item?
    /// Fetch the season fresh instead of trusting the tile.
    ///
    /// A list item carries the season it had when the home screen loaded. After
    /// finishing a season and queueing the next one, the tile keeps the old one, so the
    /// page opened with "Play S6E1" on top and season 5 in the episode list. Same
    /// pattern and same remedy as the resume point in `HomeView.starte`.
    @State private var freshSeasonID: String?
    @State private var freshSeasonNumber: Int?
    /// Refresh the season number too, not only the id.
    ///
    /// The server does not always return a `SeasonId` for an episode. In that case
    /// only the number decides the comparison, and the tile's number is stale. Linux
    /// refreshes both; iPhone and Mac only refreshed the id.

    /// Prefetched values are shown immediately, so the empty page never appears. A
    /// value delivered later would arrive too late: the empty pass has already been
    /// drawn and is what the user sees.
    @MainActor init(model: AppModel, episode: Item, back: @escaping () -> Void) {
        self.model = model
        self.episode = episode
        self.back = back
        _series = State(initialValue: SeriesCache.shared.series(for: episode, with: model))
    }

    var body: some View {
        Group {
            if let series {
                SeriesView(model: model, series: series,
                           startSeasonID: freshSeasonID ?? episode.seasonId,
                           startSeasonNumber: freshSeasonNumber ?? episode.parentIndexNumber,
                           back: back)
            } else {
                // No progress ring: the page arrives on its own right away.
                Color.clear
            }
        }
        .task {
            guard let id = episode.seriesId else { return }
            async let freshValue = model.item(id: episode.id)
            if series == nil {
                let fetched = await model.item(id: id)
                if let fetched { SeriesCache.shared.remember(fetched) }
                // The whole series page is built from this value, not in the middle of the
                // transition (`InTravel`).
                await InTravel.waitFor()
                guard !Task.isCancelled else { return }
                series = fetched
            }
            let f = await freshValue
            await InTravel.waitFor()
            guard !Task.isCancelled else { return }
            freshSeasonID = f?.seasonId
            freshSeasonNumber = f?.parentIndexNumber
        }
    }
}

// MARK: - Movie

struct FilmView: View {
    let model: AppModel
    let film: Item
    let back: () -> Void

    @State private var extras: [Item] = []
    @State private var similar: [Item] = []
    @State private var collectionRails: [CollectionRail.Rail] = []
    /// Everything below the header is already resolved. See `body`.
    @State private var bottomPresent = false
    @State private var headerState = HeaderState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DetailHero(model: model, title: film, state: headerState)
                    // The header draws over what is below it.
                    //
                    // Without this, the More menu ends up behind the tab row and the episode list:
                    // they come after the header in the stack, so they draw later and on top of it.
                    .zIndex(1)

                // Everything below the header appears at once, as on iPhone (`bottomPresent` in
                // `BrowseViews.swift`). Extras, similar titles and the collection row used to fade
                // in separately and each pushed the rest down. Now the page waits for all of them
                // and fades them in together, with no placeholder or empty hint while loading.
                if bottomPresent {
                    VStack(alignment: .leading, spacing: 26) {
                        // The description is in the header, as on Apple TV; showing it here would
                        // duplicate it.
                        CastRail(model: model, folks: film.actors,
                                        origin: film.name)
                        // Extras and similar titles. Order as on iOS.
                        TitleRail(title: "Extras", entries: extras, model: model, play: true)
                        // Above "similar titles": the collection is the closer relation. Only for titles
                        // that belong to one.
                        ForEach(collectionRails, id: \.collection.id) { rail in
                            CollectionRail(model: model, rail: rail,
                                           art: LibraryGenre.art(toType: film.type))
                        }
                        TitleRail(title: "Ähnliches", entries: similar, model: model)
                        if let source = film.mediaSources?.first {
                            FileRow(source: source)
                        }
                    }
                    .padding(.horizontal, Theme.edgeSpacing)
                    .padding(.top, 26)
                    .transition(.opacity)
                }
            }
            .padding(.bottom, 40)
            // The header image color under the page, as on iPhone (`MoodReason`): the same
            // tones as on tvOS, strongest at the top right under the backdrop, fading back to
            // `reason` in OKLab over 1300 points below the header. It is applied to the content,
            // not the page: it scrolls with the header, otherwise an edge would show while
            // scrolling.
            .background(alignment: .top) {
                MoodReason(url: model.headerImageURL(for: film), since: Theme.heroHeightValue)
            }
            // Translucent instead of solid surfaces on top; see `Theme.flaecheDurchsichtig`.
            .environment(\.onImageTint, true)
            .environment(\.imageColorSource, model.headerImageURL(for: film))
        }
        .scrollIndicators(.never)
        // The milky bar at the top edge. macOS 26 places it over every scroll view by
        // itself; it was never in our code. Over the image it blends in, but on plain
        // background at the left it shows as a bar.
        //
        // Whatever the framework adds unasked must be switched off just like what we
        // write ourselves.
        .pagesScroll()
        // The content runs up under the title bar. SwiftUI otherwise insets it by the
        // title bar's safe area, leaving a dark strip above the image. The iPhone version
        // does the same.

        // Needed here too, not only on the stack. `NavigationStack` gets the override in
        // `MainView`, but for a pushed view SwiftUI adds the toolbar background again,
        // as a milky bar over the image.
        .toolbar(.hidden)
        .toolbarBackground(.hidden, for: .windowToolbar)
        // There used to be a custom gradient from `ImageColor` ending at the hero image,
        // because the buttons used `area`, and a fixed gray on a colored background
        // looks like a different color. The buttons are now translucent over the image
        // color (8 % white), so the color can run under the whole page as on iPhone.
        .background(Theme.reason)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, new in
            headerState.offset = new
        }
        .overlay(alignment: .top) {
            DetailHeader(title: film.name, state: headerState, back: back)
        }
        .task {
            async let a = model.extras(film)
            async let b = model.similar(film)
            async let c = model.collectionRails(toward: film)
            let newExtras = (await a) ?? []
            let newSimilar = (await b) ?? []
            let newCollections = await c
            await InTravel.waitFor()
            guard !Task.isCancelled else { return }
            // One fade-in, not three. Set all at once when everything is resolved.
            extras = newExtras
            similar = newSimilar
            collectionRails = newCollections
            withAnimation(Theme.reveal) { bottomPresent = true }
        }
    }
}

/// A horizontal row of posters with a heading (extras, similar titles).
struct TitleRail: View {
    @Environment(Navigator.self) private var navigator
    @Environment(\.section) private var section
    let title: LocalizedStringKey
    let entries: [Item]
    let model: AppModel
    /// Extras are meant to be played: a click starts them instead of opening a page,
    /// as on iPhone and Apple TV.
    var play = false
    @Environment(PlayControls.self) private var controls

    var body: some View {
        if !entries.isEmpty {
            // Row heading: 20 semibold in `font`, 12 spacing to the row. 16 is not part of
            // any step scale.
            VStack(alignment: .leading, spacing: 12) {
                RailTitle(text: title)
                PagingRail(margin: 0) {
                    ForEach(entries, id: \.id) { entryRecord in
                        Button {
                            if play { controls.launch(entryRecord, since: 0) }
                            else { navigator.openIt(.title(entryRecord), in: section) }
                        } label: {
                            PosterCell(title: entryRecord.name,
                                         secondLine: entryRecord.productionYear.map { "\($0)" },
                                         image: model.imageURL(for: entryRecord, portrait: true),
                                         progress: entryRecord.userData?.playedPercentage.map { $0 / 100 },
                                         mark: DisplayRules.tileMark(
                                         art: entryRecord.type,
                                         seasons: entryRecord.childCount,
                                         watched: entryRecord.userData?.played,
                                         openEpisodes: entryRecord.userData?.unplayedItemCount),
                                         symbolText: entryRecord.tileCharacter)
                        }
                        .buttonStyle(Theme.PressButton())
                        .tileMenu(entryRecord, model: model)
                    }
                }
            }
        }
    }
}


// MARK: - The shared header

/// The hero image with everything in it: poster, title, evidence, main button,
/// action row. Not to be confused with `DetailHeader`, the bar with arrow and title
/// that fades in on scroll.
///
/// The order is the iPhone's: evidence, main button, action row. Only the layout
/// differs: in the window the poster sits next to the title instead of above it,
/// because a 1400 pt wide column with one line of text would be unreadable.
struct DetailHero: View {
    @Environment(\.watchlistShown) private var watchlistShown
    let model: AppModel
    let title: Item
    /// Where the page is: only needed to pull the image along.
    let state: HeaderState
    /// The season currently open, for "Mark season as watched" in the More list.
    ///
    /// The call site used to pass a fixed `season: nil`, so macOS was the only
    /// platform without that entry: iPhone (`Shared/SeriesView.swift`) and tvOS
    /// (`tvOS/SeriesView.swift`) pass it through, and Linux has it too. The header does
    /// not know the season itself; it lives one level down in `SeriesView`, so it comes
    /// from there.
    var season: Item? = nil
    /// What the download button does on a series page.
    ///
    /// On iPhone every movie and series page has a download button in the row below
    /// the play button; for a series it opens the choice (whole series, season, single
    /// episode). Here the button was tied to `title.type != "Series"`, so a series page
    /// had none, and downloading only worked via a chip next to the season picker that
    /// nobody looks at.
    ///
    /// The choice itself needs seasons and preloaded episodes, so it stays in
    /// `SeriesView`; the header only knows the button and reports the click upward. For
    /// a movie it stays in the header: there is nothing to choose, and the download
    /// sheet hangs directly off the button.
    var loadSelection: (() -> Void)? = nil
    /// Whether the download choice is open. The button carries the state, like the
    /// More button next to it.
    var selectionOpen: Bool = false

    /// How far the content was pulled past the top edge.
    ///
    /// Pulling further up than there is content makes the offset negative. All content
    /// then moves down by that amount, which opens the gap the header image has to
    /// fill.
    ///
    /// Capped: it must stop growing at some point. Up to 200 pt it follows, beyond that
    /// it stays. Nobody pulls that far by accident, and the scroll view's spring is
    /// already taut there.
    private var pull: CGFloat { min(max(0, -state.offset), 200) }

    @State private var plan: PlaybackPlan?
    @State private var playBarTitle: Item?
    @State private var watchlist = false
    @State private var watched = false
    @State private var moreOpen = false
    @State private var loadPanelOpen = false
    @State private var message: String?
    @Environment(PlayControls.self) private var controls

    // MARK: Downloads

    /// What of this title is already on disk. `nil` means nothing.
    private var loaded: DownloadItem? { model.downloads.entries(for: title.id) }

    /// Filled means downloaded, and an arrow remains: the checkmark belongs to the
    /// question "have I watched this".
    private var loadCharacter: String {
        switch loaded?.state {
        case nil:          "arrow.down"
        case .done:      "arrow.down.circle.fill"
        case .error:      "exclamationmark.circle"
        default:           "arrow.down.circle"
        }
    }

    /// The entry a download would get. The size comes from the same source the player
    /// would use, since it is the same file.
    private var asEntry: DownloadItem? {
        guard let account = model.session?.userID else { return nil }
        let source = plan?.source ?? title.mediaSources?.first
        return DownloadItem(
            id: title.id, account: account, art: .film, title: title.name,
            runtimeTicks: title.runTimeTicks, container: source?.container,
            source: source?.id, bytes: source?.size ?? 0,
            watchState: title.userData, videoCodec: source?.videoCodec)
    }

    private var loadImages: [String: URL] {
        guard let poster = model.posterURL(itemID: title.id,
                                           mark: title.imageTags?["Primary"])
        else { return [:] }
        return [title.id: poster]
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // On the right, not full width, as on Apple TV. The image extends below the header
            // zone and its own mask ends it, so it is not clipped.
            //
            // Always some image, never none: `headerImageURL` falls back to the next episode's
            // still for a series without a backdrop, and to the poster for everything else.
            // Cropped to the wrong aspect is better than an empty header.
            Backdrop(url: model.landscapeImageURL(for: title, width: 1600)
                         ?? model.headerImageURL(for: title),
                    height: Theme.heroHeightValue * 1.62)
                // Anchor at the bottom edge, not the top.
                //
                // The content moves down when overscrolling. If the image grew top to bottom, its
                // top edge would move with it and the gap above would stay as a hard edge.
                //
                // Anchored at the bottom it grows upward by exactly the amount the content moved
                // down: the top edge stays where it was and no gap appears.
                //
                // The scale factor is therefore computed against the full image height, not the
                // height of the header zone; otherwise it would grow by a multiple of what is
                // needed and look too strong.
                .scaleEffect(1 + pull / (Theme.heroHeightValue * 1.62), anchor: .bottom)

            block
                .padding(.leading, Theme.edgeSpacing)
                .padding(.top, Theme.titleHeight + 98)
        }
        .frame(height: Theme.heroHeightValue, alignment: .topLeading)
        // Also kept current: after the player closes, the same title comes back fresh.
        .task(id: "\(title.id)|\(title.isWatched)|\(model.pagesRefresh)") {
            watchlist = title.userData?.isFavorite ?? false
            watched = title.isWatched
            // Prefetched on tile hover: the evidence is available immediately.
            if plan == nil, let already = PlanPreAdvice.plan(title.id, with: model) { plan = already }
            if title.type == "Series" {
                let state = await model.stateInSeries(title)
                await InTravel.waitFor()
                guard !Task.isCancelled else { return }
                playBarTitle = state
            }
            // The playback plan belongs to the episode, not the series.
            //
            // This used `playBarTitle?.id ?? title.id` in its own `.task`, and
            // `playBarTitle` was still `nil` at that point because the other `.task` sets
            // it. The call went out with the series id. `AppModel.plan(for:)` documents this:
            // for series and seasons the server names no MediaSource, so `nil` comes back,
            // and since the `.task` had no key it never ran again. The Direct Play evidence
            // therefore never showed on the series page.
            //
            // `PlaybackInfo` is a POST where the server touches the file, the most expensive
            // call in the app, wasted here in the middle of the transition. iOS and tvOS both
            // fetch it for the episode.
            if let target = playBarTitle ?? (title.type == "Series" ? nil : title) {
                let new = await model.plan(for: target.id)
                PlanPreAdvice.remember(title.id, new)
                await InTravel.waitFor()
                guard !Task.isCancelled else { return }
                plan = new
            }
        }
        // The button follows the title, not the run of the task above: if the fresh page
        // arrives after it, the state would otherwise not catch up.
        .onChange(of: title.userData?.isFavorite) { _, new in
            watchlist = new ?? false
        }
    }

    /// No poster. On Apple TV it was dropped because it only carried the progress bar,
    /// which now sits where it does on every other tile.
    ///
    /// Every row has a fixed height. Title, details, description and button row thus
    /// stand in the same place on every movie page, however long the title is or how
    /// much description the server returns. Without that, buttons and rows shift when
    /// paging from movie to movie and the page looks built differently each time.
    ///
    /// Same idea as `Theme.infoHeight` on tvOS: the height is fixed there, and a long
    /// title shrinks instead of moving the page.
    private var block: some View {
        // Fixed positions instead of fixed heights.
        //
        // A stack with fixed row heights should be enough, but it was not: the buttons
        // kept moving depending on what the server returned. Instead of guessing which
        // row still grows, each row now sits at a computed position. Anything too big in
        // it is clipped and moves nothing.
        //
        // 0    title        42
        // 54   details      26
        // 92   description  66   (three lines)
        // 182  button row   48
        // 230  end
        ZStack(alignment: .topLeading) {
            // The title above a hero image is the page title: 28 bold, tracking from the
            // type step. 34 was a separate step for the same role. A long title shrinks
            // instead of moving the page; a logo stays in the 42 pt slot.
            TitleMark(title: title.name, logo: model.logoURL(for: title), slot: .compartment(height: 42))
                .frame(width: 640, height: 42, alignment: .leading)
                .offset(y: 0)

            // 26, not 20, or the clip cuts off the evidence.
            //
            // This row holds the certification badge and the Direct Play evidence. Both are
            // 13 pt text with 4 pt padding above and below, so about 24 tall. Capped at 20 and
            // clipped, a strip was missing top and bottom: the badge looked different from the
            // same badge on iPhone, and the evidence looked cut off.
            //
            // 26 is the reference value: `ProofRow` in `Sources/Shared/Style.swift` keeps the
            // same row exactly that tall on iPhone, for the same reason (as tall as a badge,
            // always).
            //
            // The clip stays: it keeps the computed position of the description below, no
            // matter what the server returns. At 26 it no longer cuts anything. Same trap as
            // with episode names, where a frame that was too tight ate the descenders.
            detailsRail
                .frame(width: 640, height: 26, alignment: .leading)
                .clipped()
                .offset(y: 54)

            // The cleaned text, not the raw one. Jellyfin returns descriptions as they came
            // from the provider, with `<br>`, `<p>` and `&amp;`. The header showed them
            // literally.
            Text(verbatim: title.description ?? "")
                .font(Theme.body)
                .lineSpacing(3)
                // `schriftLeise` is a full value. Opacity changes its effect once something lies
                // beneath it, and here the hero image does.
                .foregroundStyle(Theme.fontQuiet)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(width: 640, height: 66, alignment: .topLeading)
                .clipped()
                .offset(y: 92)

            buttonRail
                .frame(height: Theme.primaryButtonHeight, alignment: .leading)
                .offset(y: 182)
        }
        .frame(width: 640, height: 230, alignment: .topLeading)
    }

    /// Year, runtime, genres, and after them the evidence line: Direct Play, rating,
    /// certification. One line, not three.
    ///
    /// The order is the TV's: rating, certification, evidence (`ProofMarks(proofLast:
    /// true)` in the detail header). The evidence arrives last, and when it came first
    /// its appearance pushed stars and certification aside.
    ///
    /// Year, runtime and genre come first because the Mac does not put them under the
    /// title in the hero image as iPhone does (there `secondaryLine` is part of
    /// `HeroHeader`); here the title block has fixed positions and no second line for it.
    private var detailsRail: some View {
        // 8 between the badges, 14 after the text, as `ProofRow` on iPhone. 14 dates
        // from when only Direct Play had a badge; between three small badges it is a hole.
        // The 6 after the text replaces a nested stack: an empty inner stack would keep
        // its spacing even without a badge (tvOS `ProofMarks`).
        HStack(spacing: 8) {
            // Details (year, runtime, genre): 12, as in `HeroHeader` on iPhone. 14 and 10 are
            // not part of any step scale.
            Text(verbatim: detailsRow)
                .font(Theme.small)
                .foregroundStyle(Theme.fontQuiet)
                .padding(.trailing, 6)
            // In the same badge as Direct Play, as in `ProofRow`; the rating used to be the
            // only bare item in the line.
            if let rating = title.communityRating {
                mark("star.fill",
                      String(format: "%.1f", rating).replacingOccurrences(of: ".", with: ","),
                      color: Theme.fontQuiet, weight: .semibold)
            }
            // Corner 8, not the default 3. Same reasoning as on iPhone: the scale uses
            // 10/12/16, and a badge with 3 next to elements with 10 was the squarest thing on
            // the page.
            //
            // All other measures come from the component itself and match iPhone: 13 medium,
            // padding 10/4, fill at 15 percent.
            if let sharing = title.ageRating {
                Badge(text: sharing, rounding: Theme.cornerSmall)
            }
            // The evidence goes last: year, runtime, stars, certification, Direct Play, as on
            // tvOS (`ProofMarks(proofLast:)`). It arrives last and so pushes nothing; it
            // only fades in (0.2 s opacity).
            if let plan {
                proof(plan).transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: 0.2), value: plan != nil)
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The Direct Play evidence as a badge, character for character the same as
    /// `ProofRow.mark` in `Sources/Shared/Style.swift`.
    ///
    /// It is a badge, not loose text. As bare symbol and word next to the outlined
    /// certification badge it gave two different shapes to two items of equal weight.
    /// Now both share the same corner and read as a pair; the color says which kind of
    /// information it is.
    ///
    /// Fifteen percent tint, not a fill: the white play button stays the only filled
    /// object on the page. At around a third it would turn into a second button.
    ///
    /// Why copied instead of shared: `ProofRow` lives in `Sources/Shared/Style.swift`,
    /// which is not part of the Mac target (`Sources/macOS/Style.swift` applies there).
    /// Until the component moves to a file both targets include (such as
    /// `Sources/Shared/Components.swift`, where `Badge` already is), this is a second
    /// copy. It is marked as such so the two do not drift apart unnoticed.
    @ViewBuilder
    private func proof(_ plan: PlaybackPlan) -> some View {
        // Semibold only on the checkmark. The warning is regular: what makes it loud is
        // the color, not the weight. iPhone splits it the same way.
        mark(plan.isLossless ? "checkmark" : "exclamationmark.triangle.fill",
              plan.isLossless ? String(localized: "Direct Play") : plan.method.rawValue,
              color: plan.isLossless ? Theme.accent : Theme.warning,
              weight: plan.isLossless ? .semibold : .regular)
    }

    /// The badge shell for evidence and rating, as `ProofRow.mark` on iPhone.
    private func mark(_ symbol: String, _ word: String,
                       color: Color, weight: Font.Weight) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: weight))
                .accessibilityHidden(true)
            Text(verbatim: word).font(Theme.tile)
        }
        .foregroundStyle(color)
        // Narrower on the left than on the right: the symbol is narrower than its glyph
        // cell, and otherwise the word sits visibly off-center.
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.15),
                    in: RoundedRectangle(cornerRadius: Theme.cornerSmall,
                                         style: .continuous))
    }

    /// Four targets as on Apple TV: resume, from the beginning, watchlist, More.
    /// "Gesehen" (watched) and "Trailer" moved into the More list: five labeled buttons
    /// were too many for one row.
    private var buttonRail: some View {
        HStack(spacing: 12) {
            // Fixed width for the main button, but no placeholder.
            //
            // The fixed width stays: otherwise the button would grow with its label ("Fortsetzen"
            // is longer than "Abspielen") and push everything behind it. "Von vorn" (from the
            // beginning) only exists for titles already started; where it does not, the rest
            // moves up. Leaving an empty gap would be worse than the small shift.
            if let since = (playBarTitle ?? title).resumeFrom {
                PrimaryButton(label: "Fortsetzen") { start(since) }
                    .frame(width: Theme.primaryButtonWidth)
                    // Right click: the title's tile menu, as on its tile.
                    .tileMenu(title, model: model, afterwards: { await refresh() })
                ActionButton(mass: Theme.primaryButtonHeight, symbol: "arrow.counterclockwise", title: "Von vorn") {
                    start(0)
                }
            } else {
                PrimaryButton(label: "Abspielen") { start(0) }
                    .frame(width: Theme.primaryButtonWidth)
                    .tileMenu(title, model: model, afterwards: { await refresh() })
            }

            if watchlistShown {
                ActionButton(mass: Theme.primaryButtonHeight, symbol: watchlist ? "bookmark.fill" : "bookmark",
                           title: "Merkliste", active: watchlist) {
                    watchlist.toggle()
                    Task {
                        if let reason = await model.setWatchlist(title, an: watchlist) {
                            watchlist.toggle()
                            notify(reason)
                        }
                    }
                }
            }

            // The download button, only when the feature is on.
            //
            // On iPhone it is the fifth field of a row; here the secondary buttons sit side by
            // side, so it is one more. It comes after the watchlist: the two are the "for
            // later" pair and belong together.
            //
            // For a series it opens the choice, for a movie the download sheet. Same split as
            // on iPhone: the series page calls `Ladeauswahl` and the movie page `LoadSheet`.
            // For a series it must first be decided what to download; for a movie it is the
            // one file.
            if model.downloadButtonShow, title.type == "Series",
               let loadSelection {
                ActionButton(mass: Theme.primaryButtonHeight, symbol: "arrow.down",
                             title: "Laden", active: selectionOpen, pick: loadSelection)
            }
            if model.downloadButtonShow, title.type != "Series" {
                ActionButton(mass: Theme.primaryButtonHeight, symbol: loadCharacter, title: "Laden",
                           active: loaded != nil) {
                    ringClick(loaded, model.downloads) {
                        withAnimation(Theme.leap) { loadPanelOpen.toggle() }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if loadPanelOpen, let p = asEntry {
                        LoadPanel(model: model, entries: [p], title: title.name,
                                  images: loadImages, opened: $loadPanelOpen,
                                  qualitySelect: true,
                                  failed: { notify($0) })
                            .offset(y: Theme.primaryButtonHeight + 8)
                            .transition(.expand(from: .topLeading))
                            .zIndex(30)
                    }
                }
                // A click outside closes it, same expectation as the More menu. The catcher sits
                // below the panel, not above it.
                .background {
                    if loadPanelOpen {
                        Color.black.opacity(0.001)
                            .contentShape(Rectangle())
                            .frame(width: 4000, height: 4000)
                            .onTapGesture {
                                withAnimation(Theme.leap) { loadPanelOpen = false }
                            }
                    }
                }
            }

            ActionButton(mass: Theme.primaryButtonHeight, symbol: "ellipsis", title: "Mehr", active: moreOpen) {
                withAnimation(Theme.leap) { moreOpen.toggle() }
            }
            // Right-aligned over the anchor, offset only vertically; same construction as
            // `Wahlknopf`, mirrored. This used `.offset(x: -206, ...)` on a left-aligned
            // overlay: the list's frame then lay 212 pt to the right of the visible part, and
            // `.scale(anchor: .topTrailing)` scaled from there, so the list flew in from the
            // right instead of unfolding briefly from the corner.
            .overlay(alignment: .topTrailing) {
                if moreOpen {
                    ActionList(actions: moreActions, opened: $moreOpen)
                        .offset(y: Theme.primaryButtonHeight + 8)
                        .transition(.expand(from: .topTrailing))
                        .zIndex(40)
                }
            }
            // As with the picker button: the catcher sits below the panel, and a click outside
            // closes it.
            .background {
                if moreOpen {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .frame(width: 4000, height: 4000)
                        .onTapGesture { withAnimation(Theme.leap) { moreOpen = false } }
                }
            }
            .panelEscape(moreOpen) { withAnimation(Theme.leap) { moreOpen = false } }

            if let message { HintStrip(text: message) }
            Spacer(minLength: 0)
        }
    }

    /// Year, runtime and genre, from `Item.secondaryLine` in
    /// `Sources/Shared/TitleDetails.swift`.
    ///
    /// The same computation used to be repeated here, character for character apart
    /// from the `title.` prefix. It contains the `seconds > 0` check, which was once
    /// missing on tvOS: series showed "0 Min." because the server returns 0 for them. A
    /// second copy means it gets missed again next time.
    private var detailsRow: String { title.secondaryLine }

    private func start(_ since: Double) {
        controls.launch(playBarTitle ?? title, since: since)
    }

    /// The same actions as on the other platforms, from `TitleActions`, plus
    /// "Gesehen" (watched) and "Trailer", which are also here on Apple TV instead of in
    /// the button row.
    private var moreActions: [TitleAction] {
        var list: [TitleAction] = [
            // From the shared component next to the tile menu, not as a separate entry; see
            // `TitleAction.watchState`.
            .watchState(title, model: model, watched: $watched, report: { notify($0) }),
            .init(symbol: "film", text: "Trailer") { trailerStart() },
        ]
        if title.type == "Series" {
            list += TitleActions.forSeries(
                title, state: playBarTitle, season: season, model: model,
                episodeStart: { episode, since in controls.launch(episode, since: since) },
                report: { notify($0) }, refresh: { await refresh() },
                // Replaces "Nächste Folge abspielen" (play next episode), as on iPhone and iPad.
                gemeinsam: SharedModel.shared.mayCreate
                    ? { SharedModel.shared.createFor = $0 } : nil)
        } else {
            list += TitleActions.forMovie(
                title, plan: plan, model: model,
                start: { since in controls.launch(title, since: since) },
                report: { notify($0) }, refresh: { await refresh() },
                gemeinsam: SharedModel.shared.mayCreate
                    ? { [title] in SharedModel.shared.createFor = title } : nil)
        }
        return list
    }

    private func trailerStart() {
        Task {
            if let film = await model.trailer(toward: title) {
                controls.launch(film, since: 0)
                return
            }
            if let address = title.remoteTrailers?.compactMap(\.url).first,
               let target = URL(string: address) {
                NSWorkspace.shared.open(target)
                return
            }
            notify(String(localized: "Für diesen Titel liegt kein Trailer vor."))
        }
    }

    private func refresh() async {
        if title.type == "Series" { playBarTitle = await model.stateInSeries(title) }
        plan = await model.plan(for: playBarTitle?.id ?? title.id)
    }

    private func notify(_ text: String) {
        message = text
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation { message = nil }
        }
    }
}

// MARK: - Detail page building blocks

// `Description` was a text block nobody called. The description has been in the
// header since the rework, as on Apple TV; the component was left over and still
// read on every change.

struct CastRail: View {
    @Environment(Navigator.self) private var navigator
    @Environment(\.section) private var section
    let model: AppModel
    let folks: [Person]
    /// Where you came from; shown on the person page above the role.
    var origin: String? = nil

    var body: some View {
        if !folks.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                RailTitle(text: "Besetzung")
                PagingRail(margin: 0, widthJePiece: 84 + 18, imageHeight: 84) {
                    ForEach(folks, id: \.id) { person in
                        // A header is now a link: tapping the cast used to lead nowhere.
                        Button {
                            navigator.openIt(.person(person, origin: origin), in: section)
                        } label: {
                            HeaderImage(name: person.name, role: person.role,
                                     image: model.personImage(person))
                        }
                        .buttonStyle(Theme.PressButton())
                    }
                }
            }
        }
    }
}



struct HeaderImage: View {
    let name: String
    let role: String?
    let image: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                Theme.area
                // With a symbol, like every other missing image on the Mac. Without it, the cast
                // row was the only place left with a blank gray circle.
                NetworkImage(url: image, symbolText: "person", displayEdge: 76)
            }
            .frame(width: 76, height: 76)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: name)
                    .font(Theme.secondLine.weight(.medium))
                    .foregroundStyle(Theme.font)
                    .lineLimit(2)
                if let role {
                    Text(verbatim: role)
                        .font(Theme.secondLine)
                        .foregroundStyle(Theme.fontQuiet)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: 84, alignment: .leading)
    }
}

/// Last on the page: what kind of file this is. It answers a question people only
/// ask later.
///
/// The texts come from `FileDetails` in the package: container, codec and
/// subtitles are the same information on all platforms. An earlier version built
/// them locally and left out codec and subtitles.
struct FileRow: View {
    let source: MediaSource

    var body: some View {
        HStack(spacing: 22) {
            ForEach(details, id: \.self) { text in Text(verbatim: text) }
        }
        .font(Theme.secondLine)
        .foregroundStyle(Theme.fontVeryQuiet)
        .padding(.top, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var details: [String] {
        var rows: [String] = []
        // The size belongs to "MKV · 10.3 GB"; on its own it only appears when the server
        // names no container. It used to appear twice, unnoticed because a leading " · "
        // disguised it.
        if let container = FileDetails.container(source) {
            rows.append(container)
        } else {
            rows.append(FileDetails.size(source))
        }
        if let track = FileDetails.videoTrack(source) {
            rows.append(FileDetails.video(track, source))
        }
        let ut = FileDetails.subtitle(FileDetails.subtitleTracks(source))
        if !ut.isEmpty { rows.append(ut) }
        return rows.filter { !$0.isEmpty }
    }
}
