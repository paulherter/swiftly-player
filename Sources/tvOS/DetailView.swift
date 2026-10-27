import JellyfinKit
import SwiftUI

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
                .padding(.top, 140 + Theme.headerOffsetDetail)
        }
        // Not clipped: the backdrop is 700 high and may overhang downward, its own
        // gradient ends it. The first row draws over it as the next sibling.
        // 566 instead of 510: the zone grows by the same offset as the text inside,
        // else the gap to the first row would be 56 smaller than in the layout.
        .frame(height: Theme.heroHeightDetail, alignment: .topLeading)
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
            .animation(Theme.motion(.easeOut(duration: 0.3)), value: plan != nil)

            // The button row may grow wider than the text's 1000. The cap therefore sits
            // on the text, not on the whole block; once it sat outside and every label
            // was cut off. 36 from the layout. Since `infoHeight` is fixed, the row
            // sits at 490 on **every** detail page.
            buttons()
                .padding(.top, 36)
        }
    }

}

// MARK: - Watchlist and watched

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
                    Image(systemName: remembered ? "bookmark.fill" : "bookmark")
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

    @State private var freshValue: Item?
    @State private var plan: PlaybackPlan?
    /// Counts the fetches of title and plan; only the newest writes (open and
    /// refresh can overtake each other).
    @State private var titleRun = 0
    @State private var remembered = false
    @State private var watched = false
    @State private var message: String?
    /// The player sits in the frame; see `MainView`.
    @Environment(\.playRequest) private var play
    /// **Everything below the header is answered:** collection, similar, extras,
    /// cast. Set in the same animated transaction as the data, so it fades in
    /// every time, even when the caches already had everything. It used to hang
    /// on the page appearing, so rows faded in separately as their data arrived,
    /// and the collection row came last as its own fetch. Before that, the fade
    /// hung on data arriving and was hard from the second opening. The shared
    /// switch fixes both.
    @State private var bottomPresent = false
    @State private var collectionRails: [AppModel.CollectionRailsData] = []
    /// **Where focus returns when a panel closes.**
    /// It used to jump to the main button, the page's initial focus, though the
    /// user stood at the More button or season pill. A panel is not a change of
    /// place but opens above its button; closing it returns to the button
    /// that opened it.
    @FocusState private var atMoreButton: Bool
    /// **Initial focus belongs on the main button.**
    /// It was set nowhere, so tvOS picked geometrically and arrivals from search
    /// landed on "Merkliste". The series page now sets it explicitly; the movie
    /// page had only happened to be right because focus mostly came from the top
    /// left.
    @FocusState private var atPrimaryButton: Bool
    /// **Where focus returns when the player closes.**
    /// Same reason as `atMoreButton`, for the player: it is a sibling in the
    /// frame and the page stays mounted during playback, only `disabled`, which
    /// resets `atPrimaryButton`/`atMoreButton` to `false`. Without this memory tvOS
    /// picks something geometrically on removal and lands on the first tab of the
    /// header bar.
    private enum FocusTarget { case primaryButton, moreButton }
    @State private var lastFocus: FocusTarget = .primaryButton

    @State private var prepares = false
    /// The start position waiting for the version choice; `nil` while no dialog is open.
    @State private var versionSince: Double?
    @State private var similar: [Item] = []
    @State private var extras: [Item] = []
    @State private var moreOpen = false

    private var current: Item { freshValue ?? item }
    private var actors: [Person] { (current.people ?? []).filter(\.isCast) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                // **Everything below the header arrives at once**, as on the iPhone
                // (`bottomPresent` in `BrowseViews.swift`). Collection, similar, extras and cast
                // used to arrive one by one, the collection row even loaded itself and came
                // last. Now the page waits for all and fades them in together.
                if bottomPresent {
                    VStack(alignment: .leading, spacing: 0) {
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
                            // **The trailer lives here**, not as a sixth pill. A trailer is something to
                            // play, not information; a shelf slot fits better than a line in the action
                            // panel.
                            railsSection {
                                RailTitle(text: "Extras")
                            } content: {
                                TitleStrip(model: model, items: extras) { extra in
                                    launch(extra, since: 0)
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
        // **The side margin is granted once, not twice.**
        // tvOS keeps 80 pt free left and right by itself, and the page adds
        // `Theme.edgePage` (also 80): 160 together, twice the layout, which always
        // measures from 80. So the system margin is dropped here, and `edgePage`
        // measures from the screen edge afterwards.
        //
        // **On each page individually, not on the frame.** On the frame it has no
        // effect: the `NavigationStack` in `stack(b)` resets the safe area for its
        // content. Measured: the wordmark moved, the content below did not.
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
        // press used to jump out of the open panel into the content behind it, and
        // the panel stayed until the page was left.
        // Locking happens **before** the modifiers: the panels hang after and so
        // stay operable themselves.
        .defaultFocus($atPrimaryButton, true, priority: .userInitiated)
        .onChange(of: moreOpen) { _, opened in if !opened { atMoreButton = true } }
        .onChange(of: atPrimaryButton) { _, an in if an { lastFocus = .primaryButton } }
        .onChange(of: atMoreButton) { _, an in if an { lastFocus = .moreButton } }
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
        .disabled(moreOpen)
        // The remote's select opens the choice; the dialog takes the focus and gives
        // it back to the button on close.
        .confirmationDialog("Fassung wählen", isPresented: Binding(
            get: { versionSince != nil }, set: { if !$0 { versionSince = nil } }),
                            titleVisibility: .visible) {
            ForEach(versions, id: \.id) { version in
                Button(versionLabel(version)) {
                    launch(since: versionSince ?? 0, sourceID: version.id)
                }
            }
        }
        // Under the More button, at its edge; see `PanelAnchor`. The button sits at
        // the far right and the panel is wider, so `Handlungstafel.left` clamps it
        // to the button's right edge instead of letting it run off screen.
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
        // Reload after the player: it is a layer above, and `.task` does not run
        // twice. See `AppModel.playbackEnded`.
        .onChange(of: model.pagesRefresh) { _, _ in Task { await refresh() } }
        .task {
            titleRun += 1
            let myOwn = titleRun
            async let freshTitle = model.item(id: item.id)
            async let planning = model.plan(for: item.id)
            async let alike = model.similar(item)
            async let extra = model.extras(item)
            async let preview = model.trailer(toward: item)
            async let collection = model.collectionRails(toward: item)
            // **Fade in once, not three times.**
            // `.transition` alone does not work: it acts only when the change happens in
            // an **animated transaction**, and values from `await` carry none. So at
            // first everything appeared hard though the transitions were attached.
            // Three separate `withAnimation` calls (title and plan, extras, episodes)
            // then each faded on their own and overlapped into flicker. Now **everything
            // is awaited and shown once**.
            // Instant stays what was already on the home page: title, details,
            // description, image, background. Only what is new is faded.
            // **Title and plan first, immediately.** The main button, watchlist, watched
            // and the Direct Play mark depend only on these two; they do not wait for
            // trailer and collections.
            let newTitle = await freshTitle
            let newPlan = await planning
            if myOwn == titleRun {
                withAnimation(Theme.motion(.easeOut(duration: 0.32))) {
                    if let newTitle { freshValue = newTitle }
                    plan = newPlan
                }
                remembered = current.userData?.isFavorite ?? false
                watched = current.isWatched
            }
            let newSimilar = ListRules.withoutDouble((await alike) ?? [])

            // The trailer leads the extras: it was once its own pill, and the layout's
            // button row has no room for it. Dropping it would be wrong; a trailer is
            // something to play, and the shelf is the place for it.
            var shelf = (await extra) ?? []
            if let preview = await preview { shelf.insert(preview, at: 0) }
            let newCollections = await collection

            withAnimation(Theme.motion(.easeOut(duration: 0.32))) {
                similar = newSimilar
                extras = shelf
                collectionRails = newCollections
                bottomPresent = true
            }
        }
    }

    /// Backdrop, text and button row.
    /// **One labeled button, the rest are symbols.** That is also the one-main-button rule, one main
    /// button per page, read more strictly: what is not the main button need not
    /// spread like one. Five labeled pills were about 1400 pt wide and read as
    /// five equal offers. Now "Fortsetzen" or "Abspielen" carries the text, next
    /// to three square symbols: back, watchlist, more. Each names itself
    /// explicitly for VoiceOver, since a symbol button inherits no label.
    /// **Long press on the main button: the title's tile menu**, the same as on
    /// its tile (``TileMenu``).
    private var header: some View {
        DetailHeader(model: model, item: current, plan: plan) {
            HStack(spacing: 24) {
                if let since = current.resumeFrom {
                    Button { start(since: since) } label: {
                        Label("Fortsetzen", systemImage: "play.fill")
                    }
                    .buttonStyle(ThemedButtonStyle())
                    .disabled(prepares)
                    .focused($atPrimaryButton)
                    .tileMenu(current, model: model)

                    // Explicit in the layout: otherwise someone who has started could only get
                    // back to the beginning through the panel.
                    Button { start(since: 0) } label: {
                        Image(systemName: "arrow.counterclockwise").font(Theme.button)
                    }
                    .buttonStyle(ThemedButtonStyle(onlySymbol: true))
                    .accessibilityLabel(Text("Von vorn"))
                    .disabled(prepares)
                } else {
                    Button { start(since: 0) } label: {
                        Label("Abspielen", systemImage: "play.fill")
                    }
                    .buttonStyle(ThemedButtonStyle())
                    .disabled(prepares)
                    .focused($atPrimaryButton)
                    .tileMenu(current, model: model)
                }

                StateButtons(model: model, item: current,
                                remembered: $remembered, watched: $watched, message: $message)

                MoreButton(opened: $moreOpen)
                    .focused($atMoreButton)
                    .panelTrigger("mehr")
            }
        }
    }

    // MARK: Start

    /// Back to the button or episode where the user last stood.
    private func focusBack() {
        switch lastFocus {
        case .primaryButton: atPrimaryButton = true
        case .moreButton: atMoreButton = true
        }
    }

    private var moreActions: [TitleAction] {
        // Watched sits first, as it is what the panel is now opened for most often.
        // The shared list stays untouched.
        [TitleAction.watchState(current, model: model, watched: $watched,
                                 report: { message = $0 })]
        + TitleActions.forMovie(current, plan: plan, model: model,
                                   start: { launch(since: $0) },
                                   report: { message = $0 },
                                   gemeinsam: SharedModel.shared.mayCreate
                                       ? { [current] in SharedModel.shared.createFor = current } : nil)
    }

    private func refresh() async {
        // The plan too: it carries the Direct Play proof, and a state without its
        // plan is half a state.
        titleRun += 1
        let myOwn = titleRun
        async let freshTitle = model.item(id: item.id)
        async let planning = model.plan(for: item.id)
        let new = await freshTitle
        let newPlan = await planning
        guard myOwn == titleRun else { return }
        if let new { freshValue = new }
        plan = newPlan
        remembered = current.userData?.isFavorite ?? false
        watched = current.isWatched
    }

    /// The versions to choose from; empty when there is no choice to make or the
    /// title is on the device (the downloaded file is the one that plays). A
    /// download still running does not count: playback then streams from the server.
    private var versions: [MediaSource] {
        model.downloads.file(for: current.id) == nil ? MediaVersions.choices(current.mediaSources) : []
    }

    private func versionLabel(_ version: MediaSource) -> String {
        let detail = version.versionDetail
        return detail.isEmpty ? version.versionName : "\(version.versionName) · \(detail)"
    }

    /// **A title with several versions asks which one on press**, as on iPhone. One
    /// version, or a copy on the device, starts at once. The preloaded `plan` is only
    /// the proof row's; playback always fetches its own through `PlayRequest.start`,
    /// so a picked version never plays the cheapest one's plan.
    private func start(since: Double) {
        if versions.isEmpty { launch(since: since) } else { versionSince = since }
    }

    /// Freshly fetched: the position in the list entry is often stale.
    private func launch(since: Double, sourceID: String? = nil) {
        launch(current, since: since, freshValue: true, sourceID: sourceID)
    }

    /// Start a title, the same one or an extra.
    private func launch(_ title: Item, since: Double, freshValue: Bool = false, sourceID: String? = nil) {
        PlayRequest.start(title, since: since, freshValue: freshValue, sourceID: sourceID,
                              model: model, prepares: $prepares,
                              missing: { message = String(localized: "Der Server hat keine Datei zu diesem Titel.") },
                              play: { play.wrappedValue = $0 })
    }
}
