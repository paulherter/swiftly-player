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
                        WatchersRow(model: model, item: film)
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
                    .padding(.horizontal, DetailPageMetric.left)
                    .padding(.top, 36)
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
                MoodReason(url: model.headerImageURL(for: film), since: DetailPageMetric.heroImage)
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
    @State private var overviewOpen = false
    /// A series page leaves the description out, as in the design: its head ends at the buttons
    /// and the tabs follow at once.
    var showsOverview: Bool = true
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
        guard let account = model.session?.storageAccount else { return nil }
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
        // **A normal flow, no fixed positions.** The block used to sit in a 640 x 230 box with
        // every row at a computed offset; a long title or a late description then overlapped the
        // row below. Rows now stack with the gaps from the design, and the one thing that must
        // not move (the chips row, which fills in late) keeps a fixed height instead.
        block
            .padding(.leading, DetailPageMetric.left)
            .padding(.top, DetailPageMetric.top)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // **The image is a background, so it takes no room.** It is 402 high plus the 52
            // of the title bar and fades out on its own mask (bottom and left); the content
            // flows over it and sets the header's height.
            .background(alignment: .top) {
                // On the right, not full width, as on Apple TV. Always some image, never none:
                // `headerImageURL` falls back to the next episode's still for a series without
                // a backdrop, and to the poster for everything else.
                Backdrop(url: model.landscapeImageURL(for: title, width: 1600)
                             ?? model.headerImageURL(for: title),
                         height: DetailPageMetric.heroImage)
                    // Anchor at the bottom edge, not the top.
                    //
                    // The content moves down when overscrolling. If the image grew top to
                    // bottom, its top edge would move with it and the gap above would stay as a
                    // hard edge. Anchored at the bottom it grows upward by exactly the amount the
                    // content moved down. The scale factor is computed against the full image
                    // height so it does not grow by a multiple of what is needed.
                    .scaleEffect(1 + pull / DetailPageMetric.heroImage, anchor: .bottom)
            }
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

    /// Title, details, chips, buttons, progress, description. No logo image: the title
    /// is text in the design font, 44 heavy, so every page has the same head.
    private var block: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: title.name)
                .font(.app(size: 44, weight: .heavy))
                .tracking(-1.2)
                .foregroundStyle(Theme.font)
                // A long title shrinks instead of wrapping into the meta line.
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(height: 44, alignment: .leading)

            Text(verbatim: detailsRow)
                .font(.app(size: 14))
                // A full value: opacity would change its effect over the hero image.
                .foregroundStyle(Theme.fontQuiet)
                .lineLimit(1)
                .padding(.top, 12)

            chipRail
                .padding(.top, 14)

            buttonRail
                .padding(.top, 20)

            if let share = progressShare, let rest = (playBarTitle ?? title).remainingTimeText {
                VStack(alignment: .leading, spacing: 6) {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule().fill(Theme.accent)
                            .frame(width: DetailPageMetric.primaryWidth * min(max(share, 0), 1))
                    }
                    .frame(width: DetailPageMetric.primaryWidth, height: 4)
                    Text(verbatim: rest)
                        .font(.app(size: 12))
                        .foregroundStyle(Theme.fontVeryQuiet)
                }
                .padding(.top, 16)
            }

            if showsOverview { overview.padding(.top, 36) }
        }
        .frame(width: 700, alignment: .topLeading)
    }

    /// How far into the film: the server's percentage, else computed from the resume point.
    /// Not for a series: the bar would describe the next episode, not the series.
    private var progressShare: Double? {
        guard title.type != "Series", (playBarTitle ?? title).resumeFrom != nil else { return nil }
        if let share = title.watchedShare { return share }
        guard let total = title.runtimeSeconds, total > 0, let since = title.resumeFrom else { return nil }
        return since / total
    }

    /// The description at 620 wide, 14 quiet, two lines with an accent "Mehr" inline; one tap
    /// opens it in full. The cut is by characters because a button cannot sit inside running
    /// text, and a 620 pt line holds about 85 characters at this size.
    private var overview: some View {
        let text = title.description ?? ""
        let cut = 150
        let long = text.count > cut + 20
        return VStack(alignment: .leading, spacing: 8) {
            if !text.isEmpty {
                Group {
                    if long && !overviewOpen {
                        let head = String(text.prefix(cut))
                        let clean = head.lastIndex(of: " ").map { String(head[..<$0]) } ?? head
                        Text(verbatim: clean + "… ")
                            .foregroundStyle(Theme.fontQuiet)
                        + Text("Mehr").foregroundStyle(Theme.accent).fontWeight(.semibold)
                    } else {
                        Text(verbatim: text).foregroundStyle(Theme.fontQuiet)
                    }
                }
                .font(.app(size: 14))
                // 1.55 line height: Inter's own is about 1.21 at this size.
                .lineSpacing(4.5)
                .multilineTextAlignment(.leading)
                .frame(width: 620, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { if long { withAnimation(Theme.leap) { overviewOpen.toggle() } } }
                .accessibilityAddTraits(long ? .isButton : [])
            }
            if !title.direction.isEmpty {
                HStack(spacing: 8) {
                    Text("Regie").foregroundStyle(Theme.fontVeryQuiet)
                    Text(verbatim: title.direction.joined(separator: ", ")).foregroundStyle(Theme.font)
                }
                .font(.app(size: 13))
                .lineLimit(1)
            }
        }
    }

    /// Meta line: year, runtime, genres. A series has no runtime but a season count, so
    /// that takes the runtime's place (`secondaryLine` knows nothing of it).
    private var detailsRow: String {
        guard title.type == "Series" else { return title.secondaryLine }
        var parts: [String] = []
        if let year = title.productionYear { parts.append(String(year)) }
        if let count = title.childCount, count > 0 { parts.append(String(localized: "\(count) Staffeln")) }
        if let genres = title.genres, !genres.isEmpty { parts.append(genres.prefix(2).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    /// Direct Play, rating, age: 26 high chips. **Fixed height even when empty**: the evidence
    /// arrives last, and without the height the buttons would jump when it does.
    private var chipRail: some View {
        HStack(spacing: 8) {
            // The evidence is the one chip in accent: quiet surface, accent text. The warning
            // keeps its own color when the server transcodes.
            if let plan {
                if plan.isLossless {
                    chip(symbol: "checkmark", text: String(localized: "Direct Play"),
                         color: Theme.accent, fill: Theme.accentQuiet)
                        .transition(.opacity)
                } else {
                    chip(symbol: "exclamationmark.triangle.fill", text: plan.method.rawValue,
                         color: Theme.warning, fill: Theme.warning.opacity(0.15))
                        .transition(.opacity)
                }
            }
            if let rating = title.communityRating {
                chip(symbol: "star.fill",
                     text: String(format: "%.1f", rating).replacingOccurrences(of: ".", with: ","),
                     color: Theme.font, fill: Color.white.opacity(0.08))
            }
            if let age = title.ageRating {
                chip(symbol: nil, text: ageText(age), color: Theme.font, fill: Color.white.opacity(0.08))
            }
        }
        .animation(.easeOut(duration: 0.2), value: plan != nil)
        .frame(height: 26, alignment: .leading)
    }

    /// "12", "12+" and "FSK 12" all read "ab 12"; names of other systems ("PG-13") stay.
    private func ageText(_ raw: String) -> String {
        let bare = raw.replacingOccurrences(of: "FSK ", with: "").replacingOccurrences(of: "+", with: "")
        return !bare.isEmpty && bare.allSatisfy(\.isNumber) ? String(localized: "ab \(bare)") : raw
    }

    private func chip(symbol: String?, text: String, color: Color, fill: Color) -> some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(icon: symbol, size: 12).font(.app(size: 12, weight: .semibold))
                    .accessibilityHidden(true)
            }
            Text(verbatim: text).font(.app(size: 12, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// The label of the main button. A series continues with the episode the server names
    /// ("Weiter mit S1 · F3"); a title that was never started plays from the top.
    private var playLabel: String {
        if title.type == "Series" {
            if let episode = playBarTitle, let code = episode.episodeCode,
               episode.resumeFrom != nil || (episode.parentIndexNumber ?? 1) > 1 || (episode.indexNumber ?? 1) > 1 {
                return String(localized: "Weiter mit \(code)")
            }
            return String(localized: "Abspielen")
        }
        return (playBarTitle ?? title).resumeFrom != nil ? String(localized: "Fortsetzen") : String(localized: "Abspielen")
    }

    /// Main button 280 x 56, then four icon buttons without a field. "Von vorn" and the
    /// download live in the More list (`moreActions`) so no function is lost; the right-click
    /// menu on the main button has them too.
    private var buttonRail: some View {
        HStack(spacing: 4) {
            DetailPlayButton(label: playLabel) { start((playBarTitle ?? title).resumeFrom ?? 0) }
                // Right click: the title's tile menu, as on its tile.
                .tileMenu(title, model: model, afterwards: { await refresh() })
            Color.clear.frame(width: 8, height: 1)

            if watchlistShown {
                DetailIconButton(symbol: watchlist ? "bookmark.fill" : "bookmark",
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

            // A series has no trailer field (its row is watchlist and watched); its trailer
            // stays in More.
            if title.type != "Series" {
                DetailIconButton(symbol: "play.rectangle", title: "Trailer") { trailerStart() }
            }
            DetailIconButton(symbol: watched ? "checkmark.circle.fill" : "checkmark.circle",
                             title: watched ? "Als ungesehen markieren" : "Als gesehen markieren",
                             active: watched) {
                watchState.perform()
            }

            DetailIconButton(symbol: "ellipsis", title: "Mehr", active: moreOpen) {
                withAnimation(Theme.leap) { moreOpen.toggle() }
            }
            // Right-aligned over the anchor, offset only vertically, so the list unfolds from
            // the corner under the button.
            .overlay(alignment: .topTrailing) {
                if moreOpen {
                    ActionList(actions: moreActions, opened: $moreOpen)
                        .offset(y: DetailPageMetric.buttonHeight + 4)
                        .transition(.expand(from: .topTrailing))
                        .zIndex(40)
                }
            }
            // The movie's download sheet hangs off the same button now that the download is an
            // entry of its list.
            .overlay(alignment: .topTrailing) {
                if loadPanelOpen, let p = asEntry {
                    LoadPanel(model: model, entries: [p], title: title.name,
                              images: loadImages, opened: $loadPanelOpen,
                              qualitySelect: true,
                              audioStreams: (plan?.source ?? title.mediaSources?.first)?.mediaStreams ?? [],
                              failed: { notify($0) })
                        .offset(y: DetailPageMetric.buttonHeight + 4)
                        .transition(.expand(from: .topTrailing))
                        .zIndex(30)
                }
            }
            // A click outside closes either panel; the catcher sits below the panel, not above.
            .background {
                if moreOpen || loadPanelOpen {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .frame(width: 4000, height: 4000)
                        .onTapGesture {
                            withAnimation(Theme.leap) { moreOpen = false; loadPanelOpen = false }
                        }
                }
            }
            .panelEscape(moreOpen || loadPanelOpen) {
                withAnimation(Theme.leap) { moreOpen = false; loadPanelOpen = false }
            }

            if let message { HintStrip(text: message).padding(.leading, 12) }
            Spacer(minLength: 0)
        }
        .frame(height: DetailPageMetric.buttonHeight, alignment: .leading)
    }

    /// Year, runtime and genre, from `Item.secondaryLine` in
    /// `Sources/Shared/TitleDetails.swift`.
    ///
    /// The same computation used to be repeated here, character for character apart
    /// from the `title.` prefix. It contains the `seconds > 0` check, which was once
    /// missing on tvOS: series showed "0 Min." because the server returns 0 for them. A
    /// second copy means it gets missed again next time.
    /// **Play asks which version on press** when a title has several, as on iPhone; the
    /// decision and the dialog live in ``PlayControls`` so every play button on the Mac
    /// behaves the same. One version, or a copy on the device, starts at once.
    private func start(_ since: Double) {
        controls.launch(playBarTitle ?? title, since: since)
    }

    /// The same actions as on the other platforms, from `TitleActions`.
    private var moreActions: [TitleAction] {
        // Watched (and, for a movie, the trailer) sit in the button row now.
        var list: [TitleAction] = title.type == "Series"
            ? [.init(symbol: "film", text: "Trailer") { trailerStart() }]
            : []
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
        // The download left the button row for this list. A series asks what to download first
        // (season, episode); a movie opens its sheet under the More button.
        if title.type == "Series", let loadSelection {
            list.append(.init(symbol: "arrow.down.circle", text: "Laden") { loadSelection() })
        } else if title.type != "Series", model.downloadButtonShow {
            list.append(.init(symbol: loadCharacter, text: "Laden") {
                ringClick(loaded, model.downloads) { withAnimation(Theme.leap) { loadPanelOpen.toggle() } }
            })
        }
        list.insert(contentsOf: TitleActions.playOn(title.type == "Series" ? playBarTitle : title, model: model),
                    at: 0)
        return list
    }

    /// The shared watched toggle, so the row field and every menu do the same; see
    /// `TitleAction.watchState`.
    private var watchState: TitleAction {
        .watchState(title, model: model, watched: $watched, report: { notify($0) })
    }

    private func trailerStart() {
        Task {
            // Same order as on every platform (``TrailerChoice``): files the server keeps,
            // then the linked page in the browser. A file the server cannot describe is
            // skipped for the next candidate.
            let candidates = await model.trailerCandidates(for: title, canOpenWeb: true)
            if candidates.isEmpty {
                notify(String(localized: "Für diesen Titel liegt kein Trailer vor."))
                return
            }
            await controls.launchTrailer(candidates) { NSWorkspace.shared.open($0) }
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
                PagingRail(margin: 0, widthJePiece: 84 + 22, imageHeight: 84) {
                    ForEach(folks, id: \.id) { person in
                        // A header is now a link: tapping the cast used to lead nowhere.
                        Button {
                            navigator.openIt(.person(person, origin: origin), in: section)
                        } label: {
                            HeaderImage(name: person.name, role: person.role,
                                     image: model.personImage(person))
                                // 12 from the rail plus 10 here is the 22 between circles.
                                .padding(.trailing, 10)
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
                NetworkImage(url: image, symbolText: "person", displayEdge: 84)
            }
            .frame(width: 84, height: 84)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: name)
                    .font(.app(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.font)
                    .lineLimit(2)
                if let role {
                    Text(verbatim: role)
                        .font(.app(size: 12))
                        .foregroundStyle(Theme.fontVeryQuiet)
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


// MARK: - Head of the detail pages (film and series)

/// Measures of the new head, in one place so `SeriesView` lines up with the film page.
/// Declared here, not in Style.swift, which other work is editing at the same time.
enum DetailPageMetric {
    /// Left edge of everything on the page.
    static let left: CGFloat = 36
    /// Top of the title below the page top (hero 402 high, title bar included).
    static let top: CGFloat = 172
    /// Backdrop height: the 402 of the design plus the 52 of the title bar above it.
    static let heroImage: CGFloat = 454
    static let primaryWidth: CGFloat = 280
    static let buttonHeight: CGFloat = 56
    /// Bottom edge of the button row: 172 + title 44 + 12 + meta 17 + 14 + chips 26 + 20 + 56.
    static let railBottom: CGFloat = 361
}

/// The white main button: 280 x 56, radius 10, 17 semibold, play icon 18.
fileprivate struct DetailPlayButton: View {
    let label: String
    let action: () -> Void
    @State private var hovers = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(icon: "play.fill", size: 18).font(.app(size: 18))
                    .accessibilityHidden(true)
                Text(verbatim: label).font(.app(size: 17, weight: .semibold))
            }
            .foregroundStyle(Theme.reason)
            .frame(width: DetailPageMetric.primaryWidth, height: DetailPageMetric.buttonHeight)
            .background(hovers ? Theme.primaryButtonHovers : Color.white,
                        in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .onHover { hovers = $0 }
        .accessibilityLabel(label)
    }
}

/// Icon button 48 x 56 without a field: only the glyph, brighter on hover, accent when on.
fileprivate struct DetailIconButton: View {
    let symbol: String
    let title: LocalizedStringKey
    var active = false
    let action: () -> Void
    @State private var hovers = false

    var body: some View {
        Button(action: action) {
            Image(icon: symbol, size: 22).font(.app(size: 22))
                .foregroundStyle(active ? Theme.accent : Theme.font)
                .opacity(hovers || active ? 1 : 0.85)
                .frame(width: 48, height: DetailPageMetric.buttonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
        .onHover { hovers = $0 }
        .help(Text(title))
        .accessibilityLabel(Text(title))
    }
}
