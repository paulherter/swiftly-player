import JellyfinKit
import SwiftUI

struct PosterTile: View {
    let model: AppModel
    let item: Item
    /// In a grid the tile fills its column; in a row it has its fixed size.
    /// With a fixed size only two columns fit side by side and a wide gap
    /// remained on the right.
    var width: CGFloat? = Theme.tileWidth
    /// Supplied info instead of the tile's own.
    ///
    /// The result list says more than a library: kind, year, seasons,
    /// **runtime**. When the grid replaced the rows, the runtime was lost, and
    /// the same search said less on iPad than on iPhone. The result-count rule applies to result
    /// lists too.
    var inquiry: String?
    /// **Collection tiles only:** collection and section from which a
    /// substitute poster is built if the collection has none of its own.
    var mosaicSource: (collection: ItemCollection, art: String)? = nil

    /// For an episode the series is shown on top and the number below;
    /// otherwise title and year.
    ///
    /// The same rule as in the row on the home page. It was missing here as
    /// long as this poster showed only movies and series; since wide search
    /// shows a grid instead of rows, episodes land in it too and appeared
    /// without any hint which one they are.
    private var titleLine: String {
        item.type == "Episode" ? (item.seriesName ?? item.name) : item.name
    }

    private var subline: String? {
        if let inquiry { return inquiry }
        if item.type == "Episode" { return item.episodeCode }
        return item.productionYear.map(String.init)
    }

    /// **Poster and text fade in together.**
    ///
    /// The image fades in by itself since the rework, but the title below was
    /// there immediately: on a library switch the labels showed first and the
    /// posters faded in afterwards. The tile therefore fades in as a whole,
    /// and the image inside brings its own soft transition.
    @State private var present = false

    /// **The poster, or its substitute.**
    ///
    /// A collection without its own cover would otherwise get only the movie
    /// symbol, which says nothing for a collection of five movies.
    /// `mosaicSource` is set only on the collection tile; everywhere else it
    /// is `nil`, and this shows exactly the poster as before.
    @ViewBuilder
    private var poster: some View {
        if let mosaicSource, item.imageTags?["Primary"] == nil {
            CollectionMosaic(model: model, collection: mosaicSource.collection,
                            art: mosaicSource.art, width: width)
        } else {
            Picture(url: model.imageURL(for: item, maxHeight: 500, portrait: true),
                 width: width,
                 height: width.map { $0 * 1.5 },
                 ratio: width == nil ? 2.0 / 3.0 : nil,
                 corner: Theme.cornerTile,
                 progress: item.userData?.playedPercentage.map { $0 / 100 }) {
                Theme.area.overlay {
                    Image(systemName: "film").foregroundStyle(Theme.fontVeryQuiet)
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Fixed width: fixed height. If the tile fills its column, the height
            // follows the actual width at 2:3, like every poster.
            poster
            // **Three states, three marks.** A bar means started, a checkmark means
            // watched, a number means that many are here. Until now there was only the
            // bar, which says nothing for a series because it shows the state of the
            // started episode, not of the series.
            .overlay(alignment: .topTrailing) {
                if let mark = DisplayRules.tileMark(
                    art: item.type,
                    seasons: item.childCount,
                    watched: item.userData?.played,
                    openEpisodes: item.userData?.unplayedItemCount) {
                    TileBadge(mark: mark)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                // **Single line.** Two lines would make the tiles of a row end at
                // different heights, and the longer title would push its info down.
                // Truncated with an ellipsis, not wrapped.
                Text(titleLine)
                    .font(Theme.tile)
                    .foregroundStyle(Theme.font)
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
                if let subline {
                    Text(subline)
                        .font(Theme.small)
                        // The info under a poster is the quietest tone, not the middle one:
                        // `schriftLeise` is for body text and values, not a year under a title.
                        .foregroundStyle(Theme.fontVeryQuiet)
                        // The full search info needs two lines at 138 pt. In the library there
                        // is only a year, so one line is enough.
                        .lineLimit(inquiry == nil ? 1 : 2)
                }
            }
            // **The text is as wide as the poster, not as the title.**
            //
            // There was no limit here. A `VStack` is as wide as its widest child, and
            // a single-line text only truncates when given a width; otherwise it
            // grows. In a row with fixed tile width the tile became wider than its
            // poster, and a long title ran off to the right beyond the row. It was
            // noticeable only on the last tile, since there is room on the right; on
            // the others it pushed behind the neighbor.
            //
            // In the grid the column sets the width, so `infinity`.
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
        }
        // In the grid SwiftUI centers the cells of a row. With two-line titles
        // the shorter tiles slid down and the posters no longer lined up.
        .frame(maxHeight: .infinity, alignment: .top)
        .opacity(present ? 1 : 0)
        .onAppear {
            guard !present else { return }
            withAnimation(Theme.reveal) { present = true }
        }
        // One statement per tile instead of two fragments, and progress is
        // included: it is a drawing in the image and was missing for VoiceOver.
        // With year or season and episode, and "watched" from the badge.
        // Search supplies its own info; that one wins.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: inquiry.map { "\(titleLine), \($0)" } ?? item.tileAnnouncement))
        .accessibilityValue(Text(verbatim: item.tileState))
    }
}


// MARK: - Single title

struct ItemDetailView: View {
    let model: AppModel
    let item: Item

    @Environment(\.dismiss) private var back
    @Environment(\.wide) private var wide
    @Environment(\.broad) private var broad
    @Environment(\.watchlistShown) private var watchlistShown

    /// How far it has scrolled; the header fades in accordingly.
    ///
    /// **Not as `@State` here.** Every scroll step would rebuild the whole
    /// `body`: hero image with `GeometryReader`, info line, button row, three
    /// rows, file excerpt. On the movie page scrolling visibly stuttered, on
    /// the lighter series page it did not. Now only `DetailHeaderReader` reads
    /// the value, the same fix as `Scrollweg` on the home page.
    @State private var distance = ScrollDistance()

    @State private var plan: PlaybackPlan?
    /// The plan has been answered, with or without a result. See `proofRow`.
    @State private var planPresent = false
    @State private var loadSheet = false
    @State private var examine = true
    @State private var play: PlayRequest?
    /// Blocks a second tap while a plan is being fetched on press.
    @State private var prepares = false
    @State private var moreOpen = false
    @State private var message: String?
    @State private var freshValue: Item?
    @State private var similar: [Item] = []
    /// **`[]` and "failed" are two things.** The "Similar titles" section
    /// vanished without a trace on a network error, while the series page two
    /// files away said "Nothing similar found": two answers to the same
    /// question, both wrong.
    @State private var similarDisturbed = false
    @State private var extras: [Item] = []
    @State private var collectionRails: [CollectionRail.Rail] = []
    /// Everything below the description has been answered. See `body`.
    @State private var bottomPresent = false
    /// Initial value from the list object: watchlist bookmark and watched
    /// checkmark are correct from the first frame, not only after the last
    /// request. `frisch` only catches up.
    @State private var remembered: Bool
    @State private var watched: Bool

    @MainActor init(model: AppModel, item: Item) {
        self.model = model
        self.item = item
        _remembered = State(initialValue: item.userData?.isFavorite ?? false)
        _watched = State(initialValue: item.userData?.played ?? false)
    }

    private var current: Item { freshValue ?? item }

    /// What of this title is already on the device; `nil` means nothing.
    private var loaded: DownloadItem? { model.downloads.entries(for: current.id) }

    /// The entry a download would get. The size comes from the same source
    /// the player would use: it is the same file.
    private var asEntry: DownloadItem? {
        guard let account = model.session?.userID else { return nil }
        let source = plan?.source ?? current.mediaSources?.first
        return DownloadItem(
            id: current.id, account: account, art: .film, title: current.name,
            runtimeTicks: current.runTimeTicks, container: source?.container,
            source: source?.id, bytes: source?.size ?? 0,
            watchState: current.userData, videoCodec: source?.videoCodec)
    }

    private var resumeFrom: Double? { current.resumeFrom }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.reason.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if wide {
                        HeroHeader(image: model.headerImageURL(for: current),
                                 poster: model.imageURL(for: current, maxHeight: 600,
                                                        portrait: true),
                                 title: current.name, logo: model.logoURL(for: current),
                                 secondaryLine: secondaryLine,
                                 progress: current.userData?.playedPercentage
                                     .map { $0 / 100 }) {
                            VStack(alignment: .leading, spacing: 14) {
                                proofRow
                                // Buttons and action row in one line: there is width here, and stacked
                                // they would sit in a half-empty column. Side by side only if it fits.
                                // In portrait the text block is 476 pt; the row needs about 620, and
                                // SwiftUI then sets the labels vertically.
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
                        // Body text gets a measure. Stretched over the full width the lines
                        // would be 140 characters long.
                        description
                            .frame(maxWidth: Theme.readWidth, alignment: .leading)
                            .padding(.horizontal, Theme.edgePageWide)
                            .padding(.top, 18)
                    } else {
                    hero
                    VStack(alignment: .leading, spacing: 14) {
                        // Above the button after all, directly under the name: below it, it sat
                        // between button and action row and separated two things that belong
                        // together.
                        proofRow
                        // **Button and row are one block, so they sit closer.** The spacing was
                        // 14, same as to everything else, but horizontally the row's fields are
                        // only 8 apart. The gap above was thus larger than between the fields,
                        // and the row read as a separate thing instead of a continuation of the
                        // button. Feedback: "so it looks like one clean element".
                        VStack(alignment: .leading, spacing: 8) {
                            primaryButton
                            actionRail
                        }
                            // The row carries its labels close under the circles; without extra
                            // space they almost touch the text below.
                            .padding(.bottom, 8)
                        description
                    }
                    .padding(.horizontal, Theme.margin(wide: wide))
                    .padding(.top, 14)
                    }

                    // **Everything below arrives at once.** Cast, extras, collection and
                    // similar used to arrive individually, pushed into the page and shoved
                    // the rest ahead of them. Now the page waits for all of them and fades
                    // them in together, like the series page: no placeholders and no
                    // empty-state hint while still loading.
                    if bottomPresent {
                        VStack(alignment: .leading, spacing: 0) {
                            cast
                            extrasRail
                            // Above "Similar titles": the collection is the closer relation. Only
                            // for titles that are in one.
                            CollectionRail(model: model, title: item, rails: collectionRails)
                            similarRail
                            // File details at the very bottom: they answer a question asked only
                            // later.
                            fileExcerpt
                        }
                        .transition(.opacity)
                    }
                }
                // **Never wider than the screen.** If a child gets wider, it becomes the
                // whole page, and a page wider than its scroll area can be dragged
                // sideways.
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                // **The color of the header image beneath the page** (experiment
                // `experiment-glas`), narrow and wide. Wide, `HeroHeader` carries its image
                // as the background and fades it out via `onImageTint` with a mask
                // instead of `reason`; beneath it lies the same mesh, computed from its
                // minimum height (iPad, 1.0.5).
                .background(alignment: .top) {
                    MoodReason(url: model.headerImageURL(for: current),
                                   since: wide ? Theme.heroHeightWide : Theme.heroHeightValue)
                }
                // Translucent instead of solid surfaces above it, see
                // `Theme.flaecheDurchsichtig`.
                .environment(\.onImageTint, true)
                .environment(\.imageColorSource, model.headerImageURL(for: current))
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(.named("blatt"))
            .ignoresSafeArea(edges: .top)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, new in
                distance.setDown(new)
            }

            // The sheet hangs on an empty surface; without `if` there would be two
            // routes to the same actions on wide windows.
            if !wide {
                ActionSheet(opened: $moreOpen, title: current.name,
                               actions: moreActions)
                    .zIndex(20)
            }
            if let entries = asEntry {
                LoadSheet(opened: $loadSheet, model: model, entries: [entries],
                          title: current.name,
                          images: [current.id: model.posterURL(
                              itemID: current.id,
                              mark: current.imageTags?["Primary"])].compactMapValues { $0 },
                          failed: { message = $0 },
                          qualitySelect: true)
                    .zIndex(20)
            }
            if let message {
                HintStrip(text: message) { self.message = nil }
                    .zIndex(21)
            }

            DetailHeaderReader(title: current.name, distance: distance) { back() }
        }

        // Wide, the panel hangs on the button instead of the bottom edge of the
        // image. The anchor comes from `asActionAnchor()`; fixed coordinates
        // would not work because the button row shifts with the label length.
        .overlayPreferenceValue(ActionAnchor.self) { anchor in
            GeometryReader { space in
                if wide, moreOpen, let anchor {
                    ActionPanel(opened: $moreOpen, title: current.name,
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
        .catchUp(at: model.pagesRefresh) { Task { await refresh() } }
        .task {
            async let freshTitle = model.item(id: item.id)
            async let planning = model.plan(for: item.id, still: true)
            async let alike = model.similar(item)
            async let extra = model.extras(item)
            async let collection = model.collectionRails(toward: item)
            // **Set title and plan together, the rest follows separately.** The
            // slowest request ("Similar", "Collections") would otherwise hold back
            // the main button with its Direct Play mark and "Continue from ..."; the
            // series page already separates this.
            let newTitle = await freshTitle
            let newPlan = await planning
            freshValue = newTitle
            plan = newPlan
            remembered = current.userData?.isFavorite ?? false
            watched = current.userData?.played ?? false
            withAnimation(Theme.reveal) { planPresent = true }
            // **Remove duplicate identifiers.** Under "Similar" the server
            // occasionally returns the same title twice, and `ForEach` maps by
            // identifier: two equal identifiers mean two equal tiles and a tap that
            // misses. The same rule as in search, home and watchlist; it was only
            // missing here.
            let freshSimilar = await alike
            // Cancelled (page covered) is not a failure; the task restarts on
            // return.
            if Task.isCancelled { return }
            // Extras are not a section with a statement: if missing, the row is
            // missing. A second error hint below the first would be the same
            // information twice.
            let newExtras = (await extra) ?? []
            let newCollections = await collection
            // **One fade-in for the rest.** Only when everything below has been
            // answered is it set all at once.
            similarDisturbed = freshSimilar == nil && similar.isEmpty
            if let freshSimilar {
                similar = ListRules.withoutDouble(freshSimilar)
            }
            extras = newExtras
            collectionRails = newCollections
            withAnimation(Theme.reveal) { bottomPresent = true }
            examine = false
        }
    }

    /// Refetch the title from the server after its state changed. Here too
    /// one function fetches everything that can change.
    ///
    /// The plan was missing. It does not change on resetting progress (the
    /// playback mode does not depend on it), but the omission was the same as
    /// on the series page, where it became visible. Two paths that should
    /// fetch the same thing, and one knows less.
    private func refresh() async {
        async let freshTitle = model.item(id: item.id)
        async let planning = model.plan(for: item.id, still: true)
        freshValue = await freshTitle
        plan = await planning
        remembered = current.userData?.isFavorite ?? false
        watched = current.userData?.played ?? false
    }

    // MARK: Parts

    /// Same height as on the series page; before it was 260 versus 300.
    private var hero: some View {
        HeroImage(url: model.headerImageURL(for: current))
            .overlay(alignment: .bottom) { HeroRunOut(image: model.headerImageURL(for: current)) }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    #if os(iOS)
                    TitleMark(title: current.name, logo: model.logoURL(for: current))
                    #else
                    Text(current.name)
                        .font(Theme.title)
                        .tracking(Theme.lockTitle)
                        .foregroundStyle(Theme.font)
                    #endif
                    Text(secondaryLine)
                        // Year, runtime, genre are one piece of info: 12. Before it was 14,
                        // which appears in no step of the scale.
                        .font(Theme.small)
                        .foregroundStyle(Theme.fontQuiet)
                        .lineLimit(1)
                }
                .padding(.horizontal, Theme.margin(wide: wide))
                .padding(.bottom, 16)
            }
    }

    /// Year, runtime and genre sit in the hero image, no longer in a line of
    /// their own below.
    private var secondaryLine: String { current.secondaryLine }

    /// **First with the plan, then as a whole.** Stars and age rating are
    /// there immediately, the Direct Play mark only with the playback plan,
    /// and it then pushed in on the left and moved the other two right. Now
    /// the line holds its place but stays invisible until the plan is there,
    /// then fades in at once. If no plan comes, it fades in anyway, just
    /// without the mark.
    private var proofRow: some View {
        ProofRow(directPlayFlag: plan?.isLossless ?? false,
                   hint: plan.map { $0.isLossless ? nil : $0.method.rawValue } ?? nil,
                   rating: current.communityRating,
                   sharing: current.ageRating)
            // **Fixed height, even when empty.** The line only comes with the plan,
            // and from the list often without rating and age rating. Empty, it had no
            // height; the button below sat higher and dropped as soon as it filled.
            // As tall as one badge, always. `height`, not `minHeight`: the rework to
            // growing type turned it into a minimum and thereby invalidated the
            // reasoning above. With larger system type the line would have grown
            // beyond 26 and the button would have jumped exactly as described. The
            // line holds only badges, and badges stay fixed.
            .frame(height: 26, alignment: .leading)
            .opacity(planPresent ? 1 : 0)
    }

    /// **One button, not two.**
    ///
    /// Below "Continue" there was a second, equally wide "Start over" button,
    /// so for a started movie two full button rows sat above the content. It
    /// was also redundant: "Play from start" has always been in the More
    /// panel (`TitleActions.forMovie`), just like "Reset progress" next to
    /// it. Feedback: "get rid of it, it's in the menu anyway".
    ///
    /// The page again has **one** main thing, and the row below starts 60
    /// points higher.
    private var primaryButton: some View {
        // **Remaining time and bar as on the series page.**
        //
        // There they have always sat under the Continue button; a started movie
        // showed only "Continue from 51:10" and left open how much is left. The
        // same question, the same answer: layout and spacing identical to
        // `SeriesView.primaryButton`.
        VStack(alignment: .leading, spacing: 9) {
            Button { launch(since: resumeFrom ?? 0) } label: {
                if let since = resumeFrom {
                    Label("Fortsetzen ab \(timeText(since))", systemImage: "play.fill")
                } else {
                    Label("Abspielen", systemImage: "play.fill")
                }
            }
            .buttonStyle(PrimaryButtonStyle(stretches: !wide))
            // Long press: the title's tile menu, as on its tile.
            .tileMenu(current, model: model)
            // Only while the plan is on its way on press. Before, the button hung on
            // the preloaded plan: if that single request failed, it stayed gray
            // forever without a word.
            .disabled(prepares)

            if let rest = current.remainingTimeText {
                // Remaining time is one piece of info: 12.
                Text(rest).growing(12).foregroundStyle(Theme.fontQuiet)
            }
            // Wide, progress sits on the poster in the header; here it would be the
            // same thing a second time, and across the whole page.
            if !wide, let share = current.userData?.playedPercentage, share > 0 {
                ProgressBar(share: share / 100)
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            }
        }
    }

    private var actionRail: some View {
        // Narrow, the spacers distribute the buttons across the row; wide, they
        // sit next to the play button and should stay together.
        HStack(spacing: 8) {
            if watchlistShown {
                ActionButton(symbol: remembered ? "bookmark.fill" : "bookmark",
                             title: "Merkliste", active: remembered, stretches: !broad) {
                    remembered.toggle()
                    // Switch immediately so the button responds, but revert if the server
                    // says no. Before, the display stayed put and lied.
                    Task {
                        if let reason = await model.setWatchlist(current, an: remembered) {
                            remembered.toggle()
                            message = reason
                        }
                    }
                }
            }
            // **The fifth field, only when the feature is on.**
            //
            // In second place, not at the end: watchlist and download are the "for
            // later" pair and belong side by side. Five fields in 354 pt give 62 each,
            // above the 44 a hit target needs.
            //
            // Whoever never enables the feature sees the row unchanged with its four
            // fields; that is why it grows here instead of always reserving a fifth
            // slot.
            if model.downloadButtonShow, current.type != "Series" {
                DownloadField(entries: loaded, stretches: !broad) {
                    ringTap(loaded, model.downloads) { loadSheet = true }
                }
            }

            ActionButton(symbol: "film", title: "Trailer", stretches: !broad) { trailerStart() }
            ActionButton(symbol: watched ? "checkmark.circle.fill" : "checkmark.circle",
                         title: "Gesehen", active: watched, stretches: !broad) {
                watched.toggle()
                Task {
                    if let reason = await model.setWatched(current, an: watched) {
                        watched.toggle()
                        message = reason
                    }
                }
            }
            ActionButton(symbol: "ellipsis", title: "Mehr", stretches: !broad) { moreOpen = true }
                .asActionAnchor()
        }
        // No margin of its own anymore: the four fields share the row and end
        // where the button above ends.
    }

    @ViewBuilder
    private var description: some View {
        if let text = current.description {
            VStack(alignment: .leading, spacing: 8) {
                // Single line with truncation, tap expands. The full text was too heavy
                // on this page.
                CollapsibleText(text: text)

                if !current.direction.isEmpty {
                    HStack(spacing: 5) {
                        Text("Regie").foregroundStyle(Theme.fontQuiet)
                        Text(current.direction.joined(separator: ", "))
                            .foregroundStyle(Theme.font)
                    }
                    // A role is one piece of info: 12. Before it was 13; that grade is
                    // Medium in the scale and belongs to the title under a poster.
                    //
                    // **Growing:** it sits under the description text, which already follows
                    // the system type (`CollapsibleText`). With a fixed line below, half the
                    // paragraph scaled and the other half did not.
                    .growing(12)
                }
            }
        }
    }

    /// The excerpt this app is about.
    @ViewBuilder
    private var fileExcerpt: some View {
        if let source = plan?.source {
            VStack(alignment: .leading, spacing: 0) {
                // **Take back its own margin.** `Gruppentitel` indents itself by
                // `edgeSpacing`, and the stack here wraps the side margin around it once
                // more: "File" sat twice as far in as its rows and as "Cast" below.
                GroupsTitle(text: "Datei")
                    .padding(.horizontal, -Theme.edgeSpacing)
                    .padding(.top, 22)
                Rectangle().fill(Theme.line).frame(height: 1)
                if source.container != nil {
                    FileRow(designation: "Container", value: FileDetails.container(source) ?? "")
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
                if let video = source.mediaStreams?.first(where: { $0.type == "Video" }) {
                    FileRow(designation: "Video", value: FileDetails.video(video, source))
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
                ForEach(Array((source.mediaStreams ?? []).filter { $0.type == "Audio" }.prefix(2).enumerated()),
                        id: \.offset) { pair in
                    FileRow(designation: pair.offset == 0 ? "Ton" : " ",
                               value: pair.element.short)
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
                let subtitle = (source.mediaStreams ?? []).filter { $0.type == "Subtitle" }
                FileRow(designation: "Untertitel",
                           value: FileDetails.subtitle(subtitle))
                Rectangle().fill(Theme.line).frame(height: 1)
            }
            .padding(.horizontal, Theme.margin(wide: wide))
        }
    }

    @ViewBuilder
    private var cast: some View {
        let folks = current.actors
        if !folks.isEmpty {
            // **Tappable now**, and the arrow is gone: it promised a full list that
            // never existed. A tap opens the person: what exists for them on the
            // server, and with Seerr what can be requested. Reported by a tester.
            Segment(title: "Besetzung") {
                HStack(spacing: 14) {
                    ForEach(folks.prefix(12)) { person in
                        NavigationLink(value: PersonRoute(person: person, origin: current.name)) {
                            CastTile(image: model.personImage(person),
                                             name: person.name, role: person.role)
                        }
                        .buttonStyle(Theme.PressButton())
                    }
                }
                .padding(.horizontal, Theme.margin(wide: wide))
            }
        }
    }

    @ViewBuilder
    private var extrasRail: some View {
        if !extras.isEmpty {
            Segment(title: "Extras") {
                HStack(spacing: 12) {
                    ForEach(extras) { extra in
                        ExtraTile(model: model, extra: extra, prepares: $prepares,
                                    missing: { message = String(localized: "Der Server hat keine Datei zu diesem Titel.") }) {
                            play = $0
                        }
                    }
                }
                .padding(.horizontal, Theme.margin(wide: wide))
            }
        }
    }

    @ViewBuilder
    private var similarRail: some View {
        if similar.isEmpty {
            // Only if the fetch failed. A collection without related items needs no
            // section.
            if similarDisturbed {
                // **Not `Abschnitt`.** It puts its content in a horizontal scroll area,
                // and there a hint meant to take the full width collapses to its text
                // width.
                VStack(alignment: .leading, spacing: 12) {
                    RailTitle(text: "Ähnliche Titel")
                        .padding(.horizontal, Theme.margin(wide: wide))
                    DisturbHint(model: model, retry: { againSimilar() },
                                 spacingTop: 0)
                }
                .padding(.top, Theme.railsSpacing)
            }
        } else {
            Segment(title: "Ähnliche Titel") {
                LazyHStack(spacing: Theme.tileSpacing) {
                    ForEach(similar) { title in
                        NavigationLink(value: title) {
                            PosterTile(model: model, item: title)
                        }
                        .buttonStyle(Theme.PressButton())
                    }
                }
                .padding(.horizontal, Theme.margin(wide: wide))
            }
        }
    }

    private func launch(since: Double) {
        Theme.jerk(.medium)
        if let plan {
            play = PlayRequest(item: current, plan: plan, startAt: since)
            return
        }
        // **No preloaded plan**: still on its way or failed. Then fetch on
        // press, as on the series page, and say so if that fails too.
        PlayRequest.start(current, since: since, model: model, prepares: $prepares,
                              missing: { message = String(localized: "Der Server hat keine Datei zu diesem Titel.") },
                              play: { wish in
                                  plan = wish.plan
                                  play = wish
                              })
    }

    /// Retry only that one row; reloading the whole page would be too much
    /// for one failed section.
    private func againSimilar() {
        Task {
            let freshValue = await model.similar(item)
            similarDisturbed = freshValue == nil
            if let freshValue { similar = ListRules.withoutDouble(freshValue) }
        }
    }

}

/// Section with a heading and horizontally scrolling content.
struct Segment<ContentBody: View>: View {
    @Environment(\.wide) private var wide
    let title: LocalizedStringKey
    var arrow = false
    @ViewBuilder var content: () -> ContentBody

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 5) {
                // **Not set by itself.** The grade was the same, the tracking was
                // missing: "Continue watching" on the home page has -0.3, "Cast" here
                // had zero. On the Seerr page both forms now meet.
                RailTitle(text: title)
                if arrow {
                    Image(systemName: "chevron.right")
                        // A chevron is 13 semibold. Before it was 12 semibold; at 12 the scale
                        // has Regular, and a semibold chevron in a Regular grade is none of the
                        // steps.
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.fontVeryQuiet)
                }
            }
            .padding(.horizontal, Theme.margin(wide: wide))

            ScrollView(.horizontal, showsIndicators: false) {
                content()
                    #if os(iOS)
                    // **The pull from the left edge belongs to the page.** Without this the
                    // row caught it: on the person page "On your server" slid in instead of
                    // the page going back. In the content, not as a background, see
                    // `SwipeRow`.
                    .overlay(alignment: .topLeading) {
                        EdgeGesturePreRank().frame(width: 0, height: 0)
                    }
                    #endif
            }
        }
        // 28, not 26: "row to row" is one number, and the
                        // home page uses 28. Two rhythms for the same layout are noticeable
                        // when tapping through.
                        .padding(.top, Theme.railsSpacing)
    }
}

extension ItemDetailView {

    func trailerStart() {
        TrailerStart.start(current, model: model,
                             play: { play = $0 },
                             report: { message = $0 })
    }

    var moreActions: [TitleAction] {
        TitleActions.forMovie(current, plan: plan, model: model,
                                 start: { launch(since: $0) },
                                 report: { message = $0 },
                                 gemeinsam: SharedModel.shared.mayCreate
                                     ? { [current] in SharedModel.shared.createFor = current } : nil)
    }
}
