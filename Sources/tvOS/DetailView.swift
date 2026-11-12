import JellyfinKit
import SwiftUI
import SwiftlyCore

// MARK: - Header shared by movie and series

/// Backdrop, title, details, description and button row: the upper half of
/// every detail page.
/// On the iPhone movie and series pages are **the same page**: same header,
/// same proof line, same white button, same action row. Only the button label
/// changes, and series add the episodes below. The header is therefore one
/// component, not two copies.
/// **510 high, not 1080.** The header used to fill the screen with the poster
/// on the left. Now it takes the home page's header zone: backdrop right, text
/// left, and the rows start at 534, **the same line as the first row title on
/// the home page** (510 + `Theme.railsHeaderPadding`). Going from home to detail
/// keeps the rows in place, which ties the two pages together.
/// The poster is gone. It carried the progress bar, which now sits where it
/// does on every other tile: on the episode in the row below.
/// No back arrow and no tab bar: the page is pushed, not a level of the home
/// page. Back is the Menu button on tvOS.
struct DetailHeader<Buttons: View>: View {
    let model: AppModel
    let item: Item
    let plan: PlaybackPlan?
    /// Whether the header contains anything focusable at all.
    /// The series page has no button row, only text. A `focusSection` without a
    /// target is harmful, not just wasted: tvOS registers a region, routes the
    /// press there, finds nothing and drops it. The cast row got stuck on exactly
    /// that once.
    var focusable = true
    /// Pulls the first rail up; the series page's rail starts 40 above the movie page's.
    var heroTrim: CGFloat = 0
    @ViewBuilder var buttons: () -> Buttons

    @ViewBuilder
    var body: some View {
        if focusable { shell.focusSection() } else { shell }
    }

    private var shell: some View {
        ZStack(alignment: .topLeading) {
            Backdrop(url: model.landscapeImageURL(for: item, width: 1600)
                         ?? model.headerImageURL(for: item))
                .frame(maxWidth: .infinity, alignment: .trailing)

            // **Same header shadow as the home page.**
            // It has no bar to carry here, but stays anyway: it was the last layer that
            // existed on only one of the two pages. On opening it faded out, which was
            // the brightening at the top that looked like a crossfade though image and
            // mesh did not change. Same rule as for the header block, the backdrop fade
            // and the tinted background: what should look the same on both pages must be
            // the same layer, or the difference shows in the transition.
            HeaderShadow()

            block
                .padding(.leading, Theme.edgePage)
                // 140 from the layout, plus the offset that clears the undrawn header bar;
                // see `Theme.headerOffsetDetail`. Together 196, the same line as the home
                // page's title.
                .padding(.top, Theme.contentTop)
        }
        // Not clipped: the backdrop is 700 high and may overhang downward, its own
        // gradient ends it. The first row draws over it as the next sibling.
        // 566 instead of 510: the zone grows by the same offset as the text inside,
        // else the gap to the first row would be 56 smaller than in the layout.
        .frame(height: Theme.heroHeightDetail - heroTrim, alignment: .topLeading)
    }

    // **The whole header is one focus section, not just the button row.**
    // tvOS searches geometrically. Without the section, an up press from the
    // first row finds only what happens to be in the same column, and the
    // backdrop on the left is no target. With the section spanning the header,
    // every way up lands on its only focusable element: the button row. See
    // `focusable`.

    private var block: some View {
        VStack(alignment: .leading, spacing: 0) {
            // **Same component as on the home page.** The header is identical there and
            // here; only the button row is added. See `HeaderInfo`.
            HeaderInfo(item: item, logoModel: model) {
                // **The proof fades in, the rest of the header does not.** It hangs on
                // `plan`, which comes from the server; in the otherwise still header it
                // would appear in the middle. It belongs to what is new: the home page has no
                // plan fetched yet.
                if let plan {
                    ProofMarks(directPlayFlag: plan.isLossless,
                                hint: plan.isLossless ? nil : plan.method.rawValue,
                                proofLast: true)
                        .transition(.opacity)
                }
            }
            // **The fade hangs on the plan, not on the caller's transaction.**
            // `.transition` alone fades only if the plan arrives in an animated
            // transaction. The movie page sets it inside its `withAnimation`; the series
            // page sets it after the shared fade-in without animation, so the Direct Play
            // mark jumped in there. Pinned here, the fade applies to every page that
            // carries the header, however it sets its plan. The mark is last in the line,
            // so nothing shifts.
            .animation(Theme.motion(.timingCurve(0.23, 1, 0.32, 1, duration: 0.22)), value: plan != nil)

            // The button row may grow wider than the text's 1000. The cap therefore sits
            // on the text, not on the whole block; once it sat outside and every label
            // was cut off. 36 from the layout. Since `infoHeight` is fixed, the row
            // sits at 490 on **every** detail page.
            buttons()
                .padding(.top, Theme.spacingAboveButtons)
        }
    }

}

// MARK: - Watchlist and watched

/// **Watched, Shuffle and Watch together as symbol buttons** before "…" (the panel leaves them out).
/// Shuffle and Watch together only when the core's menu offers them. No motion of their own: the
/// button style's focus lift is all there is.
struct RowExtraButtons: View {
    let watched: Bool
    let actions: TVRowActions
    let onWatched: () -> Void
    let onShuffle: () -> Void
    let onTogether: () -> Void

    var body: some View {
        Button(action: onWatched) {
            Image(icon: watched ? "checkmark.circle.fill" : "checkmark.circle").font(Theme.button)
        }
        .buttonStyle(ThemedButtonStyle(onlySymbol: true, active: watched))
        .accessibilityLabel(Text("Gesehen"))
        .accessibilityAddTraits(watched ? [.isButton, .isSelected] : .isButton)

        if let entry = actions.shuffle {
            Button(action: onShuffle) { Image(icon: "shuffle").font(Theme.button) }
                .buttonStyle(ThemedButtonStyle(onlySymbol: true))
                .accessibilityLabel(Text(verbatim: entry.text))
        }
        if let entry = actions.together {
            Button(action: onTogether) { Image(icon: "person.2").font(Theme.button) }
                .buttonStyle(ThemedButtonStyle(onlySymbol: true))
                .accessibilityLabel(Text(verbatim: entry.text))
        }
    }
}

/// The watchlist button: **symbol only, no label.**
/// The bookmark is one of the few symbols that stand alone, and filled versus
/// empty states the status. Five labeled pills were too many for a row.
/// "Gesehen" is out of the row entirely and sits in the action panel; see
/// `TitleAction.watchState`. That leaves four targets: Continue, From start,
/// Watchlist, More.
/// **Without a label, the label is mandatory.** For VoiceOver a symbol button
/// is otherwise nameless, hence the explicit name.
struct StateButtons: View {
    let model: AppModel
    let item: Item
    @Binding var remembered: Bool
    @Binding var watched: Bool
    @Binding var message: String?
    @Environment(\.watchlistShown) private var watchlistShown

    var body: some View {
        Group {
            // Switched off in Appearance, the bookmark is gone; the favourite itself stays
            // on the server.
            if watchlistShown {
                Button {
                    remembered.toggle()
                    // Toggle at once so the button responds, but revert if the server says
                    // no.
                    Task {
                        if let reason = await model.setWatchlist(item, an: remembered) {
                            remembered.toggle()
                            message = reason
                        }
                    }
                } label: {
                    Image(icon: remembered ? "bookmark.fill" : "bookmark")
                        .font(Theme.button)
                }
                .buttonStyle(ThemedButtonStyle(onlySymbol: true, active: remembered))
                .accessibilityLabel(Text("Merkliste"))
                // Filled versus empty symbol is the whole difference; for VoiceOver both
                // read "Merkliste".
                .accessibilityAddTraits(remembered ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

// "Gesehen" is not a pill in the button row but in the action panel:
// **placement, not behavior**. The toggle rule requires that it toggles
// at once and the state is the answer; it still does, one level deeper. On a
// TV every focus target in the row counts, and five side by side were too
// many. The entry itself comes from the shared component
// `TitleAction.watchState` in `Sources/Shared/TileMenu.swift`.

// MARK: - Movie page

/// Header with button row, then "Ähnliche Filme", "Extras" and "Besetzung",
/// each row a `Section` as on the home page.
struct DetailView: View {
    let model: AppModel
    let item: Item

    /// The page's data owner, the core's `DetailVm` (`DetailCore`); `nil` when there is no account.
    @State private var page: DetailCore?
    @State private var message: String?
    /// The player sits in the frame; see `MainView`.
    @Environment(\.playRequest) private var play
    /// **Where focus returns when a panel closes.**
    /// It used to jump to the main button, the page's initial focus, though the
    /// user stood at the More button or season pill. A panel is not a change of
    /// place but opens above its button; closing it returns to the button
    /// that opened it.
    @FocusState private var atMoreButton: Bool
    /// **Initial focus belongs on the main button.**
    @FocusState private var atPrimaryButton: Bool
    /// **Where focus returns when the player closes.**
    /// The page stays mounted during playback, only `disabled`, which resets
    /// `atPrimaryButton`/`atMoreButton` to `false`; without this memory tvOS lands on the
    /// first tab of the header bar.
    private enum FocusTarget { case primaryButton, moreButton }
    @State private var lastFocus: FocusTarget = .primaryButton

    @State private var prepares = false
    /// A title with several versions waiting for the pick; `nil` while no dialog is open.
    @State private var versionChoice: VersionPick?
    @State private var moreOpen = false

    @MainActor init(model: AppModel, item: Item) {
        self.model = model
        self.item = item
        _page = State(initialValue: DetailCore(app: model, item: item))
    }

    private var current: Item { page?.item ?? item }
    private var actions: ActionsPart? { page?.model.actions }
    private var bottom: BottomPart? { page?.model.bottom }
    private var actors: [Person] { (bottom?.cast ?? []).map(Person.init(core:)) }
    private var similar: [Item] { (bottom?.similar ?? []).map(Item.init(rust:)) }
    private var extras: [Item] { (bottom?.extras ?? []).map(Item.init(rust:)) }
    /// The "Part of the collection" rows, as the collection view takes them.
    private var collectionRails: [AppModel.CollectionRailsData] {
        (bottom?.collections ?? []).map { rail in
            let collection = Item(id: rail.id, name: rail.title, type: "BoxSet")
            return (ItemCollection(item: collection, members: []), rail.tiles.map(Item.init(rust:)))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                // **Everything below the header arrives at once**, as on the iPhone: the core
                // answers cast, extras, similar, collections and watchers together
                // (`bottom.ready`) and the page fades them in together.
                if bottom?.ready == true {
                    VStack(alignment: .leading, spacing: 0) {
                        WatchersStrip(model: model, item: item,
                                      fromCore: (bottom?.watchers ?? []).map(Watcher.init(core:)))

                        // Above "Ähnliche Filme": the collection is the closer relation. Only for
                        // titles that belong to one.
                        CollectionRail(model: model, title: item, rails: collectionRails)

                        if !similar.isEmpty {
                            railsSection {
                                RailTitle(text: "Ähnliche Filme")
                            } content: {
                                TitleStrip(model: model, items: similar)
                            }
                        }
                        if !extras.isEmpty {
                            // **The trailer lives here**, not as a sixth pill: a trailer is something
                            // to play, and the shelf is the place for it.
                            railsSection {
                                RailTitle(text: "Extras")
                            } content: {
                                TitleStrip(model: model, items: extras) { extra in
                                    launchExtra(extra)
                                }
                            }
                        }
                        if !actors.isEmpty {
                            railsSection {
                                RailTitle(text: "Besetzung")
                            } content: {
                                CastStrip(model: model, folks: actors, origin: item.name)
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }
            .padding(.bottom, Theme.completionPadding)
        }
        .scrollIndicators(.hidden)
        // **The side margin is granted once, not twice.** tvOS keeps 80 pt free left and right by
        // itself, and the page adds `Theme.edgePage` (also 80). On each page individually, not on the
        // frame: the `NavigationStack` resets the safe area for its content.
        .ignoresSafeArea()
        // **The whole page background tints to the backdrop**, after `ignoresSafeArea` (see
        // `ImageReason`).
        .imageReason(url: model.landscapeImageURL(for: current, width: 1600)
                        ?? model.headerImageURL(for: current))
        .defaultFocus($atPrimaryButton, true, priority: .userInitiated)
        .onChange(of: moreOpen) { _, opened in if !opened { atMoreButton = true } }
        .onChange(of: atPrimaryButton) { _, an in if an { lastFocus = .primaryButton } }
        .onChange(of: atMoreButton) { _, an in if an { lastFocus = .moreButton } }
        // See `lastFocus`: the player leaves the same empty focus as an open panel.
        .onChange(of: play.wrappedValue == nil) { before, closed in
            guard closed, before == false else { return }
            focusBack()
        }
        // Same after "Gemeinsam schauen".
        .onChange(of: SharedModel.shared.createFor == nil) { before, toward in
            guard toward, before == false, play.wrappedValue == nil else { return }
            focusBack()
        }
        // **While a panel is open, the rest is not a focus target.**
        .disabled(moreOpen)
        // The remote's select opens the choice; the dialog takes the focus and gives it back on close.
        .versionPick($versionChoice) { choice, version in
            launch(page?.pressPlay(pick: version.id), since: choice.since, picked: version.id)
        }
        // Under the More button, at its edge; see `PanelAnchor`.
        .panel(under: moreOpen ? "mehr" : nil) {
            ActionPanel(actions: moreActions, opened: $moreOpen)
                .transition(.opacity)
        }
        .animation(Theme.motion(.timingCurve(0.23, 1, 0.32, 1, duration: 0.22)), value: moreOpen)
        .overlay(alignment: .top) {
            if let message {
                HintStrip(text: message) { self.message = nil; page?.model.dismissMessage() }
                    .padding(.top, Theme.edgeTop)
            }
        }
        // Reload after the player: it is a layer above, and `.task` does not run twice.
        .overlay {
            if let trouble = page?.trouble {
                DisturbState(model: model, trouble: trouble, retry: { page?.model.load() })
                    .background(Theme.reason)
                    .transition(.opacity)
            }
        }
        .animation(Theme.motion(.easeOut(duration: 0.22)), value: page?.trouble)
        .onChange(of: model.pagesRefresh) { _, _ in page?.model.refresh() }
        // The core loads the title with its plan, then cast, extras, similar and collections, and keeps
        // the page current. Cancelled (page covered) is not a failure; the task restarts on return.
        .task { await page?.run(app: model) }
        .onChange(of: actions?.effectSeq) { _, _ in drain() }
        .onChange(of: actions?.message) { _, new in if let new { message = new } }
        .onChange(of: actions?.toggleError) { _, new in if let new { message = new } }
        .onChange(of: model.watchersShown) { _, _ in page?.send(options: model) }
        .onChange(of: PlayOutputs.shared.targets.map(\.id)) { _, _ in page?.send(options: model) }
    }

    /// Backdrop, text and button row.
    /// **One labeled button, the rest are symbols.** "Fortsetzen" or "Abspielen" carries the text,
    /// next to square symbols: back to start, watchlist, more. Each names itself for VoiceOver.
    /// **Long press on the main button: the title's tile menu**, the same as on its tile.
    private var header: some View {
        let watchlist = actions?.favorite ?? false
        return DetailHeader(model: model, item: current, plan: page?.plan(app: model)) {
            HStack(spacing: 24) {
                if current.resumeFrom != nil {
                    Button { launch(page?.pressPlay(), since: nil, picked: nil) } label: {
                        Label("Fortsetzen", icon: "play.fill")
                    }
                    .buttonStyle(ThemedButtonStyle())
                    .disabled(prepares || actions?.play.enabled != true)
                    .focused($atPrimaryButton)
                    .tileMenu(current, model: model)

                    // Explicit in the layout: otherwise someone who has started could only get
                    // back to the beginning through the panel.
                    Button { launch(page?.model.playFromStart(), since: nil, picked: nil) } label: {
                        Image(icon: "arrow.counterclockwise").font(Theme.button)
                    }
                    .buttonStyle(ThemedButtonStyle(onlySymbol: true))
                    .accessibilityLabel(Text("Von vorn"))
                    .disabled(prepares || actions?.play.enabled != true)
                } else {
                    Button { launch(page?.pressPlay(), since: nil, picked: nil) } label: {
                        Label("Abspielen", icon: "play.fill")
                    }
                    .buttonStyle(ThemedButtonStyle())
                    .disabled(prepares || actions?.play.enabled != true)
                    .focused($atPrimaryButton)
                    .tileMenu(current, model: model)
                }

                // Switched off in Appearance, the bookmark is gone; the favourite itself stays on the server.
                if model.watchlistShown {
                    Button { page?.model.setWatchlist(!watchlist) } label: {
                        Image(icon: watchlist ? "bookmark.fill" : "bookmark").font(Theme.button)
                    }
                    .buttonStyle(ThemedButtonStyle(onlySymbol: true, active: watchlist))
                    .accessibilityLabel(Text("Merkliste"))
                    .accessibilityAddTraits(watchlist ? [.isButton, .isSelected] : .isButton)
                }

                // Watched and Watch together sit in the row, not in the panel.
                RowExtraButtons(watched: actions?.watched ?? false, actions: rowActions,
                                onWatched: { page?.model.setWatched(!(actions?.watched ?? false)) },
                                onShuffle: { page?.model.menu(.shuffle) },
                                onTogether: { page?.model.menu(.together) })

                MoreButton(opened: $moreOpen)
                    .focused($atMoreButton)
                    .panelTrigger("mehr")
            }
        }
    }

    private var rowActions: TVRowActions { TVRowActions(menu: page?.model.moreMenu() ?? []) }

    // MARK: Start

    /// Back to the button or episode where the user last stood.
    private func focusBack() {
        switch lastFocus {
        case .primaryButton: atPrimaryButton = true
        case .moreButton: atMoreButton = true
        }
    }

    /// The core's menu without what the row shows as buttons; the host runs what only it can.
    private var moreActions: [TitleAction] {
        guard let page else { return [] }
        return rowActions.panel.map { entry in
            TitleAction(symbol: Self.symbol(of: entry.kind), wording: entry.text) {
                switch entry.kind {
                case .playFromStart: launch(page.model.playFromStart(), since: nil, picked: nil)
                default: page.model.menu(entry.kind)
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

    // MARK: What the core asks of the host

    private func drain() {
        guard let page else { return }
        for effect in page.model.takeEffects() {
            switch effect {
            case .play(let action):
                launch(action, since: nil, picked: nil)
            case .playTrailer(let id):
                PlayRequest.start(Item(id: id, name: current.name), freshValue: true, model: model, prepares: $prepares,
                                  missing: { message = String(localized: "Der Server hat keine Datei zu diesem Titel.") },
                                  play: { play.wrappedValue = $0 })
            case .menu(let kind):
                switch kind {
                case .playOn(let id, _):
                    guard let target = PlayOutputs.shared.targets.compactMap(PlayOutput.init(session:))
                        .first(where: { $0.deviceID == id })
                    else { continue }
                    let title = current
                    Task { await PlayOutputs.shared.play(title, to: target, model: model) }
                case .together:
                    SharedModel.shared.createFor = current
                default:
                    break
                }
            case .stateChanged:
                SeriesCache.shared.forget(current.seriesId ?? current.id)
                model.noteWatchStateChanged()
            case .watchlistChanged:
                model.noteWatchlistChanged()
            case .openWeb, .openDownload:
                break
            }
        }
    }

    /// An extra plays at once.
    private func launchExtra(_ extra: Item) {
        PlayRequest.start(extra, since: 0, model: model, prepares: $prepares,
                          missing: { message = String(localized: "Der Server hat keine Datei zu diesem Titel.") },
                          play: { play.wrappedValue = $0 })
    }

    /// What a press on Play (or a menu entry that plays) does, as the core decides it.
    private func launch(_ action: PlayAction?, since: Double?, picked: String?) {
        guard let page, let action else { return }
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
            if source == nil, !downloaded, let plan = page.plan(app: model) {
                play.wrappedValue = PlayRequest(item: current, plan: plan, startAt: start)
                return
            }
            PlayRequest.start(current, since: start, sourceID: source, model: model, prepares: $prepares,
                              missing: { message = String(localized: "Der Server hat keine Datei zu diesem Titel.") },
                              play: { play.wrappedValue = $0 })
        }
    }
}
