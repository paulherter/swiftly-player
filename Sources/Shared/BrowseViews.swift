import JellyfinKit
import SwiftUI
import SwiftlyCore

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
        if let look { return look.title }
        return item.type == "Episode" ? (item.seriesName ?? item.name) : item.name
    }

    /// What the Rust core says for this tile (`AppModel.coreServes`), by title id; `nil` otherwise.
    private var look: RustTileLook? { coreLook ?? (model.coreServes ? model.rustLooks[item.id] : nil) }
    /// The look of the page's own core tile (person and playlist pages), before the shared lookup.
    var coreLook: RustTileLook? = nil

    private var subline: String? {
        if let inquiry { return inquiry }
        if let look { return look.subtitle }
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
            Picture(url: look?.image ?? model.imageURL(for: item, maxHeight: 500, portrait: true),
                 width: width,
                 height: width.map { $0 * 1.5 },
                 ratio: width == nil ? 2.0 / 3.0 : nil,
                 corner: Theme.cornerTile,
                 progress: item.userData?.playedPercentage.map { $0 / 100 }) {
                Theme.area.overlay {
                    Image(icon: "film").foregroundStyle(Theme.font)
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8)  {
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

            VStack(alignment: .leading, spacing: 2) {
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

    /// The page's data owner, the core's `DetailVm` (`DetailCore`); `nil` when there is no account.
    @State private var page: DetailCore?
    /// A title with several versions waiting for the pick ("Fassung wählen").
    @State private var versionChoice: VersionPick?
    @State private var loadSheet = false
    @State private var play: PlayRequest?
    /// Blocks a second tap while a plan is being fetched on press.
    @State private var prepares = false
    @State private var moreOpen = false
    @State private var message: String?

    @MainActor init(model: AppModel, item: Item) {
        self.model = model
        self.item = item
        _page = State(initialValue: DetailCore(app: model, item: item))
    }

    private var current: Item { page?.item ?? item }
    private var hero: HeroPart? { page?.model.hero }
    private var actions: ActionsPart? { page?.model.actions }
    private var bottom: BottomPart? { page?.model.bottom }

    /// What of this title is already on the device; `nil` means nothing.
    private var loaded: DownloadItem? { model.downloads.entries(for: current.id) }

    /// The entry a download would get. The size comes from the same source
    /// the player would use: it is the same file.
    private var asEntry: DownloadItem? {
        guard let account = model.session?.storageAccount else { return nil }
        let source = page?.plan(app: model)?.source ?? current.mediaSources?.first
        return DownloadItem(
            id: current.id, account: account, art: .film, title: current.name,
            runtimeTicks: current.runTimeTicks, container: source?.container,
            source: source?.id, bytes: source?.size ?? 0,
            watchState: current.userData, videoCodec: source?.videoCodec)
    }

    private var headerImage: URL? { hero?.image.flatMap { URL(string: $0.address) } }
    private var logoImage: URL? { hero?.logo.flatMap { URL(string: $0.address) } }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.reason.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    heroBlock
                    VStack(alignment: .leading, spacing: Theme.blockGap) {
                        // Above the button after all, directly under the name: below it, it sat
                        // between button and action row and separated two things that belong
                        // together.
                        proofRow
                        // **Button and row are one block, so they sit closer.** The spacing was
                        // 14, same as to everything else, but horizontally the row's fields are
                        // only 8 apart. The gap above was thus larger than between the fields,
                        // and the row read as a separate thing instead of a continuation of the
                        // button. Feedback: "so it looks like one clean element".
                        VStack(alignment: .leading, spacing: Theme.actionGap) {
                            primaryButton
                            actionRail
                        }
                            // The row carries its labels close under the circles; without extra
                            // space they almost touch the text below.
                            .padding(.bottom, 8)
                        description
                    }
                    .padding(.horizontal, Theme.margin(wide: wide))
                    .padding(.top, 4)

                    // **Everything below arrives at once.** Cast, extras, collection and
                    // similar used to arrive individually, pushed into the page and shoved
                    // the rest ahead of them. Now the core answers them together (`bottom.ready`)
                    // and the page fades them in at once: no placeholders and no empty-state
                    // hint while still loading.
                    if bottom?.ready == true {
                        VStack(alignment: .leading, spacing: 0) {
                            // Quiet and first: who has seen it belongs to the title itself.
                            WatchersRow(model: model, list: (bottom?.watchers ?? []).map(Watcher.init(core:)))
                            cast
                            extrasRail
                            // Above "Similar titles": the collection is the closer relation. Only
                            // for titles that are in one.
                            CollectionRail(model: model, title: current, rails: collectionRails)
                            similarRail
                            // File details at the very bottom: they answer a question asked only
                            // later.
                            fileExcerpt
                        }
                        .transition(.opacity)
                    }
                }
                // The core assigns `bottom` with no transaction, so the fade needs its own driver.
                .animation(Theme.reveal, value: bottom?.ready == true)
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
                    MoodReason(url: headerImage, since: Theme.heroHeightValue)
                }
                // Translucent instead of solid surfaces above it, see
                // `Theme.flaecheDurchsichtig`.
                .environment(\.onImageTint, true)
                .environment(\.imageColorSource, headerImage)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(.named("blatt"))
            .ignoresSafeArea(edges: .top)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, new in
                distance.setDown(new, until: Theme.heroHeightValue + MoodReason.runOut)
            }

            // The first fresh load failed: say why, with the copy of that kind, instead of a
            // half-empty page with a gray button. Retrying loads the page again.
            Group {
                if let trouble = page?.trouble {
                    EmptyState.serverDived(model, trouble: trouble, retry: { page?.model.load() })
                        .background(Theme.reason)
                }
            }
            .animation(Theme.reveal, value: page?.trouble)
            .zIndex(10)
            // The sheet hangs on an empty surface; without `if` there would be two
            // routes to the same actions on wide windows.
            ActionSheet(opened: $moreOpen, title: hero?.title ?? current.name,
                           actions: moreActions)
                .zIndex(20)
            if let entries = asEntry {
                LoadSheet(opened: $loadSheet, model: model, entries: [entries],
                          title: current.name,
                          images: [current.id: model.posterURL(
                              itemID: current.id,
                              mark: current.imageTags?["Primary"])].compactMapValues { $0 },
                          failed: { message = $0 },
                          qualitySelect: true,
                          audioStreams: (page?.plan(app: model)?.source ?? current.mediaSources?.first)?.mediaStreams ?? [])
                    .zIndex(20)
            }
            if let message {
                HintStrip(text: message) { self.message = nil; page?.model.dismissMessage() }
                    .zIndex(21)
            }

            DetailHeaderReader(title: hero?.title ?? current.name, distance: distance, mood: headerImage) { back() }
        }

        #if os(iOS)
        .background(SwipeBack())
        .toolbar(.hidden, for: .navigationBar)
        .playerCover(item: $play) { wish in
            PlayerScreen(model: model, item: wish.item,
                         plan: wish.plan, startAt: wish.startAt)
        }
        #endif
        .versionPick($versionChoice) { choice, version in
            launch(page?.pressPlay(pick: version.id), since: choice.since, picked: version.id)
        }
        .catchUp(at: model.pagesRefresh) { page?.model.refresh() }
        // The core loads the title with its plan, then cast, extras, similar and collections, and keeps the page
        // current. Cancelled (page covered) is not a failure; the task restarts on return.
        .task { await page?.run(app: model) }
        // What the core tells the host to do (open a trailer page, hand a title to another device ...).
        .onChange(of: actions?.effectSeq) { _, _ in drain() }
        .onChange(of: actions?.message) { _, new in if let new { message = new } }
        .onChange(of: actions?.toggleError) { _, new in if let new { message = new } }
        // The tiles under the page take their wording from the core, like the home page's.
        .onChange(of: bottom) { _, new in if let new { rememberLooks(new) } }
        // What the core cannot know: settings, rights, devices in reach, a copy on the device.
        .onChange(of: model.watchersShown) { _, _ in page?.send(options: model) }
        .onChange(of: model.downloadButtonShow) { _, _ in page?.send(options: model) }
        .onChange(of: model.downloads.entries.count) { _, _ in page?.send(options: model) }
        .onChange(of: PlayOutputs.shared.targets.map(\.id)) { _, _ in page?.send(options: model) }
    }

    // MARK: Parts

    /// Same height as on the series page; before it was 260 versus 300.
    private var heroBlock: some View {
        HeroImage(url: headerImage)
            .overlay(alignment: .bottom) { HeroRunOut(image: headerImage) }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    #if os(iOS)
                    TitleMark(title: hero?.title ?? current.name, logo: logoImage)
                    #else
                    Text(hero?.title ?? current.name)
                        .font(Theme.title)
                        .tracking(Theme.lockTitle)
                        .foregroundStyle(Theme.font)
                    #endif
                    Text(hero?.secondaryLine ?? "")
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

    /// **First with the plan, then as a whole.** Stars and age rating are
    /// there immediately, the Direct Play mark only with the playback plan,
    /// and it then pushed in on the left and moved the other two right. Now
    /// the line holds its place but stays invisible until the plan is there
    /// (`proof.visible`), then fades in at once. If no plan comes, it fades
    /// in anyway, just without the mark.
    private var proofRow: some View {
        let proof = actions?.proof
        return ProofRow(directPlayFlag: proof?.directPlay ?? false, hint: proof?.hint,
                        ratingText: proof?.rating, sharing: proof?.ageRating)
            // **Fixed height, even when empty.** The line only comes with the plan,
            // and from the list often without rating and age rating. Empty, it had no
            // height; the button below sat higher and dropped as soon as it filled.
            // As tall as one badge, always. `height`, not `minHeight`: the rework to
            // growing type turned it into a minimum and thereby invalidated the
            // reasoning above. With larger system type the line would have grown
            // beyond 26 and the button would have jumped exactly as described. The
            // line holds only badges, and badges stay fixed.
            .frame(height: 26, alignment: .leading)
            .opacity(proof?.visible == true ? 1 : 0)
            .animation(Theme.reveal, value: proof?.visible)
    }

    /// **One button, not two.**
    ///
    /// Below "Continue" there was a second, equally wide "Start over" button,
    /// so for a started movie two full button rows sat above the content. It
    /// was also redundant: "Play from start" has always been in the More
    /// panel, just like "Reset progress" next to it. Feedback: "get rid of
    /// it, it's in the menu anyway".
    ///
    /// The page again has **one** main thing, and the row below starts 60
    /// points higher.
    private var primaryButton: some View {
        // **Remaining time and bar as on the series page.** There they have always
        // sat under the Continue button; a started movie showed only "Continue from
        // 51:10" and left open how much is left. The same question, the same answer.
        let button = actions?.play
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                launch(page?.pressPlay(), since: nil, picked: nil)
            } label: {
                Label { Text(verbatim: button?.label ?? "") } icon: { Image(icon: "play.fill") }
            }
            .buttonStyle(PrimaryButtonStyle(stretches: true))
            // Long press: the title's tile menu, as on its tile.
            .tileMenu(current, model: model)
            // **A title with several versions asks which one on press.** 4K next to
            // 1080p, theatrical next to extended cut; the server lists them as
            // sources of one item. One version, or a copy on the device, starts at once.
            //
            // **Gray until the versions are known** (the core enables the button, and
            // enables it again when the fresh load failed so that a press tries once
            // more), and while a plan is on its way on press.
            .disabled(prepares || button?.enabled != true)

            if let rest = button?.remaining {
                // Remaining time is one piece of info: 12.
                Text(rest).growing(12).monospacedDigit().foregroundStyle(Theme.fontQuiet)
            }
            // Wide, progress sits on the poster in the header; here it would be the
            // same thing a second time, and across the whole page.
            if let share = button?.progress, share > 0 {
                ProgressBar(share: Double(share))
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            }
        }
    }

    private var actionRail: some View {
        let remembered = actions?.favorite ?? false
        let watched = actions?.watched ?? false
        // Narrow, the spacers distribute the buttons across the row; wide, they
        // sit next to the play button and should stay together.
        return HStack(spacing: 8) {
            if watchlistShown {
                ActionButton(symbol: remembered ? "bookmark.fill" : "bookmark",
                             title: "Merkliste", active: remembered, stretches: true,
                             caption: remembered ? "Gemerkt" : "Merken") {
                    // The core switches at once so the button responds, and goes back if the
                    // server says no (`toggleError`).
                    page?.model.setWatchlist(!remembered)
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
            if actions?.download != nil {
                DownloadField(entries: loaded, stretches: true, caption: "Laden") {
                    ringTap(loaded, model.downloads) { loadSheet = true }
                }
            }

            ActionButton(symbol: "play.rectangle", title: "Trailer", stretches: true,
                         caption: "Trailer") { page?.model.trailer() }
            ActionButton(symbol: watched ? "checkmark.circle.fill" : "checkmark.circle",
                         title: "Gesehen", active: watched, stretches: true,
                         caption: "Gesehen") {
                page?.model.setWatched(!watched)
            }
            ActionButton(symbol: "ellipsis", title: "Mehr", stretches: true, caption: "Mehr") { moreOpen = true }
                .asActionAnchor()
        }
        // No margin of its own anymore: the four fields share the row and end
        // where the button above ends.
    }

    @ViewBuilder
    private var description: some View {
        if let text = hero?.overview {
            VStack(alignment: .leading, spacing: 8) {
                // Single line with truncation, tap expands. The full text was too heavy
                // on this page.
                CollapsibleText(text: text)

                if let directors = hero?.directors, !directors.isEmpty {
                    HStack(spacing: 5) {
                        Text("Regie").foregroundStyle(Theme.fontQuiet)
                        Text(directors.joined(separator: ", "))
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
        if let file = bottom?.file {
            VStack(alignment: .leading, spacing: 0) {
                // **Take back its own margin.** `Gruppentitel` indents itself by
                // `edgeSpacing`, and the stack here wraps the side margin around it once
                // more: "File" sat twice as far in as its rows and as "Cast" below.
                GroupsTitle(verbatim: file.title)
                    .padding(.horizontal, -Theme.edgeSpacing)
                    .padding(.top, Theme.railsSpacing)
                Rectangle().fill(Theme.line).frame(height: 1)
                ForEach(Array(file.rows.enumerated()), id: \.offset) { pair in
                    FileRow(verbatim: pair.element.label, value: pair.element.value)
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
            }
            .padding(.horizontal, Theme.margin(wide: wide))
        }
    }

    @ViewBuilder
    private var cast: some View {
        if let folks = bottom?.cast, !folks.isEmpty {
            // **Tappable now**, and the arrow is gone: it promised a full list that
            // never existed. A tap opens the person: what exists for them on the
            // server, and with Seerr what can be requested. Reported by a tester.
            Segment(title: "Besetzung") {
                HStack(spacing: 14) {
                    ForEach(folks, id: \.id) { person in
                        NavigationLink(value: PersonRoute(person: Person(core: person), origin: current.name)) {
                            CastTile(image: person.image.flatMap { URL(string: $0.address) },
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
        if let extras = bottom?.extras, !extras.isEmpty {
            Segment(title: "Extras") {
                HStack(spacing: 12) {
                    ForEach(extras, id: \.id) { extra in
                        ExtraTile(model: model, extra: Item(rust: extra), look: RustTileLook(extra), prepares: $prepares,
                                    missing: { message = String(localized: "Der Server hat keine Datei zu diesem Titel.") }) {
                            play = $0
                        }
                    }
                }
                .padding(.horizontal, Theme.margin(wide: wide))
            }
        }
    }

    /// The "Part of the collection" rows, as the collection view takes them.
    private var collectionRails: [CollectionRail.Rail] {
        (bottom?.collections ?? []).map { rail in
            let collection = Item(id: rail.id, name: rail.title, type: "BoxSet")
            return (ItemCollection(item: collection, members: []), rail.tiles.map(Item.init(rust:)))
        }
    }

    @ViewBuilder
    private var similarRail: some View {
        let similar = bottom?.similar ?? []
        if similar.isEmpty {
            // Only if the fetch failed. A collection without related items needs no
            // section.
            if bottom?.similarFailed == true {
                // **Not `Abschnitt`.** It puts its content in a horizontal scroll area,
                // and there a hint meant to take the full width collapses to its text
                // width.
                VStack(alignment: .leading, spacing: 12) {
                    RailTitle(text: "Ähnliche Titel")
                        .padding(.horizontal, Theme.margin(wide: wide))
                    DisturbHint(model: model, retry: { page?.model.retrySimilar() },
                                 spacingTop: 0)
                }
                .padding(.top, Theme.railsSpacing)
            }
        } else {
            Segment(title: "Ähnliche Titel") {
                LazyHStack(spacing: Theme.tileSpacing) {
                    ForEach(similar, id: \.id) { tile in
                        NavigationLink(value: Item(rust: tile)) {
                            PosterTile(model: model, item: Item(rust: tile))
                        }
                        .buttonStyle(Theme.PressButton())
                    }
                }
                .padding(.horizontal, Theme.margin(wide: wide))
            }
        }
    }

    // MARK: What the core asks of the host

    /// The tiles below the page: the core's own pictures and wording, found by id.
    private func rememberLooks(_ part: BottomPart) {
        var looks: [String: RustTileLook] = [:]
        for tile in part.similar + part.extras + part.collections.flatMap(\.tiles) {
            looks[tile.id] = RustTileLook(tile)
        }
        model.rustLooks.merge(looks) { _, new in new }
    }

    private func drain() {
        guard let page else { return }
        for effect in page.model.takeEffects() {
            switch effect {
            case .play(let action):
                launch(action, since: nil, picked: nil)
            case .playTrailer(let id):
                Theme.jerk(.medium)
                PlayRequest.start(Item(id: id, name: current.name), freshValue: true, model: model, prepares: $prepares,
                                  missing: { message = String(localized: "Der Server hat keine Datei zu diesem Titel.") },
                                  play: { play = $0 })
            case .openWeb(let address):
                #if os(iOS)
                if let url = URL(string: address) { Task { await UIApplication.shared.open(url) } }
                #endif
            case .openDownload:
                if model.downloadButtonShow { ringTap(loaded, model.downloads) { loadSheet = true } }
            case .menu(let kind):
                hostMenu(kind)
            case .stateChanged:
                SeriesCache.shared.forget(current.seriesId ?? current.id)
                model.noteWatchStateChanged()
            case .watchlistChanged:
                model.noteWatchlistChanged()
            }
        }
    }

    /// The menu entries only the platform can carry out.
    private func hostMenu(_ kind: MenuKind) {
        switch kind {
        case .playOn(let id, _):
            guard let target = PlayOutputs.shared.targets.compactMap(PlayOutput.init(session:)).first(where: { $0.deviceID == id })
            else { return }
            let title = current
            Task { await PlayOutputs.shared.play(title, to: target, model: model) }
        case .together:
            SharedModel.shared.createFor = current
        case .download:
            loadSheet = true
        default:
            break
        }
    }

    /// What a press on Play (or a menu entry that plays) does, as the core decides it.
    ///
    /// `since` overrides the core's start second, `picked` is the version the user chose.
    private func launch(_ action: PlayAction?, since: Double?, picked: String?) {
        guard let page, let action else { return }
        Theme.jerk(.medium)
        let missing = { message = String(localized: "Der Server hat keine Datei zu diesem Titel.") }
        switch action {
        case .wait:
            return
        case .choose(_, let at, let versions):
            versionChoice = VersionPick(
                heading: page.model.actions.play.versionTitle, options: versions, since: since ?? at)
        case .resolve(_, let at):
            // The fresh title never came: fetch it once more and decide again; say so if that fails too.
            guard !prepares else { return }
            prepares = true
            Task {
                let again = await page.resolve(pick: picked)
                prepares = false
                if case .resolve = again {
                    message = String(localized: "Die Fassungen konnten nicht geladen werden. Probier es gleich nochmal.")
                } else {
                    launch(again, since: since ?? at, picked: picked)
                }
            }
        case .start(_, let at, let source):
            let start = since ?? at
            let downloaded = model.downloads.file(for: current.id) != nil
            // The plan the page already holds, unless a version was picked or a copy on the device decides.
            if source == nil, !downloaded, let plan = page.plan(app: model) {
                play = PlayRequest(item: current, plan: plan, startAt: start)
                return
            }
            PlayRequest.start(current, since: start, sourceID: source, model: model, prepares: $prepares,
                              missing: missing, play: { play = $0 })
        }
    }

    /// The long-press menu of the "Mehr" sheet: the core names the entries, the host runs what only it can.
    private var moreActions: [TitleAction] {
        guard let page else { return [] }
        return page.model.moreMenu().map { entry in
            TitleAction(symbol: Self.symbol(of: entry.kind), wording: entry.text) {
                switch entry.kind {
                case .playFromStart:
                    launch(page.model.playFromStart(), since: nil, picked: nil)
                default:
                    page.model.menu(entry.kind)
                }
            }
        }
    }

    private static func symbol(of kind: MenuKind) -> String {
        switch kind {
        case .playOn: "tv"
        case .playFromStart: "gobackward"
        case .resetProgress: "arrow.counterclockwise.circle"
        case .together: "person.2"
        case .refreshMetadata: "arrow.clockwise"
        default: "ellipsis"
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
                    Image(icon: "chevron.right", size: Theme.chevronSize)
                        // A chevron is 13 semibold. Before it was 12 semibold; at 12 the scale
                        // has Regular, and a semibold chevron in a Regular grade is none of the
                        // steps.
                        .font(.app(size: Theme.chevronSize, weight: .semibold))
                        .foregroundStyle(Theme.font)
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
