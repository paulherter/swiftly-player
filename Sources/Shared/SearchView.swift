import JellyfinKit
import SwiftUI
#if canImport(SwiftlyCore)
import SwiftlyCore
#endif

/// Full-text search across movies, series and episodes.
struct SearchView: View {
    let model: AppModel
    /// The area is currently open. The tab persists after the first visit, so
    /// `onAppear` is not enough - the field would only get focus the very first time.
    var active: Bool = true
    /// Swipe right when the keyboard is already closed: back to where you were.
    var back: (() -> Void)? = nil

    init(model: AppModel, active: Bool = true, back: (() -> Void)? = nil) {
        self.model = model
        self.active = active
        self.back = back
        _seerr = State(initialValue: SeerrSearchFlow(model: model))
    }

    @State private var term = ""
    @State private var hit: [Item] = []
    @State private var hunts = false
    /// **The fetch failed - not "nothing found".**
    ///
    /// The two looked the same: `search` returned an empty list on every network
    /// error, and the page then said "Nothing on your server for this". That is a
    /// false statement, and the most expensive kind - it sends you to the server
    /// instead of the Wi-Fi.
    @State private var disrupted = false
    @State private var task: Task<Void, Never>?
    /// What Seerr knows and the own server does not have: rails, the merged block, offline. Own object,
    /// own task: if Seerr answers late or not at all, what the own server has still shows at once.
    @State private var seerr: SeerrSearchFlow
    @State private var seerrTask: Task<Void, Never>?
    /// The Seerr answer for the typed word is on its way.
    @State private var seerrPending = false
    @FocusState private var inField: Bool

    /// **The page is in search state - header gone, field on top, exit on the right.**
    ///
    /// Separate from ``inField``, and that is the point: the keyboard closes on any
    /// tap into the void, the search state does not. Someone who typed something
    /// and dismisses the keyboard wants to look at the results - if the page
    /// rearranges again, everything under the thumb moves away. The way back is
    /// the exit on the right, and nothing else.
    @State private var searchMode = false
    @State private var accountSwitch = false
    /// How far the results are scrolled (0...30), for the header's fade.
    @State private var scrolled: CGFloat = 0
    /// Height of the header content (title row + field) in its resting state, measured while the page is
    /// not in search state. In search state without a word it keeps this height, see `header`.
    @State private var restHeight: CGFloat = 0

    /// **What was searched last - the last eight, newest first.**
    ///
    /// Remembered on submit, not on typing: someone typing "Ga", "Gam", "Game"
    /// searched once, not three times.
    ///
    /// **Per account** (`SearchHistory.key(account:)`): the kids profile saw the
    /// parent profile's searches after a switch. The old shared entry is assigned
    /// to the active account on first use.
    @State private var lastRaw = ""

    @Environment(\.wide) private var wide
    @Environment(\.windowButtons) private var windowButtons
    /// The second tap on the already open tab - see `MainView`.
    @Environment(\.tabStillTimes) private var anotherTime

    private var last: [String] { SearchHistory.list(lastRaw) }

    /// The rules are in `SearchHistory`, the storage in `SearchHistoryStore` - the TV shows the same list.
    // CORE-GAP: `SearchModel.recents` / `pick` / `clearRecents` export the same history (same
    // `letzteSuchen.<account>` strings); the view still keeps its own copy for the TV, which shares it.
    private func historyLoad() {
        lastRaw = SearchHistoryStore.load(account: model.session?.accountKey)
    }

    private func historySet(_ new: String) {
        lastRaw = new
        SearchHistoryStore.save(new, account: model.session?.accountKey)
    }

    private func remember(_ word: String) {
        historySet(SearchHistory.remember(word, in: lastRaw))
    }

    // MARK: Header

    /// **Title and field hang in `BlurHeader`, like the other root pages.**
    ///
    /// They used to sit in a column above the results with 16 pt of empty space under the field, so
    /// scrolling up cut the results off at a hard edge about a centimetre below the field and
    /// the strip in between stayed black. Now the header is a safe-area inset of the scroll area: the
    /// results run underneath and the same gradient (`HeaderHistory`) fades in with the scroll
    /// distance as on Start, Movies and Series.
    private var header: some View {
        BlurHeader(offset: scrolled) {
            VStack(spacing: 0) {
                if !searchMode {
                    // Centered so title and profile mark sit on one line - like every other root page.
                    HStack(alignment: .center, spacing: 0) {
                        Text("Suche").font(Theme.titleLarge).tracking(Theme.lockTitle)
                        Spacer(minLength: 0)
                        if !wide {
                            HeaderTargets(name: model.session?.userName ?? "?",
                                          image: model.userImageURL())
                        }
                    }
                    .foregroundStyle(Theme.font)
                    .padding(.bottom, 12)
                    // **Only fade out, do not slide away.** With `.move(edge: .top)` the header slid up
                    // out of the picture together with its `HeaderHistory`; the field moves up anyway
                    // once the title needs no space, so the motion arises from layout.
                    .transition(.opacity)
                }
                HStack(spacing: 12) {
                    SearchField(text: $term, atTap: $inField,
                             submit: { remember(term) })
                        // One measure wide, but left-aligned: centered it would be offset against
                        // the grid below, across the full width a 1036 pt long box for one word.
                        .frame(maxWidth: wide ? Theme.readWidth : .infinity,
                               alignment: .leading)

                    // **The exit sits next to the field, not inside it.** The clear button is
                    // already in the field and clears only the word; this one closes the keyboard.
                    // Two crosses next to each other would be two meanings in one glyph.
                    // Wide as well as narrow: the exit belongs to the search state, not the
                    // window size. Without it you could not leave search on iPad at all - there
                    // is no swipe-back gesture there that would catch it when narrow.
                    if searchMode {
                        Button {
                            // The exit clears the page: word gone, keyboard closed, header back. The
                            // cross **in** the field clears only the word - two glyphs, two scopes.
                            term = ""
                            inField = false
                            searchMode = false
                        } label: {
                            Image(icon: "xmark", size: 15)
                                .font(Theme.listTitle)
                                .foregroundStyle(Theme.font)
                                .frame(width: 36, height: 36)
                                .background(Theme.area, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(Theme.PressButton())
                        .accessibilityLabel(Text("Suche schließen"))
                        // **It comes last and goes first.**
                        //
                        // On the same curve as the rest it was already there while the profile image
                        // was still fading out - one lay over the other and it looked like it popped
                        // up. With a delay it waits until the column has rearranged and the header is
                        // gone, then appears in the free space. On closing the other way round: gone
                        // at once so it does not get in the profile image's way.
                        .transition(.asymmetric(
                            insertion: .opacity.animation(Theme.sheetMotion.delay(0.14)),
                            removal: .opacity.animation(.easeOut(duration: 0.09))))
                    }

                    if wide { Spacer(minLength: 0) }
                }
                .padding(.top, wide ? (searchMode ? 0 : Theme.headerTop + (windowButtons ? WindowButtons.height : 0))
                                    : (searchMode ? 8 : 4))
                // `BlurHeader` brings 12 under its content; the field keeps its 16 to the results.
                .padding(.bottom, 4)
            }
            // **The header keeps its height while the page changes into search state.**
            //
            // The header is the scroll view's safe-area inset. When the title row went away the inset
            // shrank by the title row (194 -> 142 pt measured) and the scroll view moved the content up
            // by the same amount, wherever it was scrolled. Now the field moves up inside an unchanged
            // header, so the inset stays and the content stands still. Once a word is typed the results
            // replace the content anyway, and the header closes up to the field.
            .onGeometryChange(for: CGFloat?.self) { searchMode ? nil : $0.size.height } action: {
                if let height = $0 { restHeight = height }
            }
            .frame(minHeight: searchMode && term.isEmpty ? restHeight : 0, alignment: .top)
        }
        // **Only the header animates on `searchMode`** - never the scroll view that it insets (see `body`).
        .animation(Theme.sheetMotion, value: searchMode)
    }

    var body: some View {
        ZStack {
            Theme.reason.ignoresSafeArea()

            GeometryReader { frameRect in
            // **The animation sits on the header, not on the column around the scroll view.**
            //
            // It sat on this whole column, and then the scroll view's safe-area inset (the
            // header's height) was animated too: when the title row went away the top
            // `contentInsets` dived from 194 to ~1 and sprang back to 142 in the last frame, while
            // the offset moved the other way (measured per frame). The inset layer of the scroll
            // view followed that curve, which matches the grey layer reported on the page: a layer
            // that runs down and vanishes at the end. Without an animation there the inset does not
            // dive; title, field and exit button still move because the animation hangs on the
            // header itself, and the header keeps its height so the inset does not change at all
            // (see `header`).
            VStack(spacing: 0) {
                // **A header on the search page after all.**
                //
                // There was none, and the reasoning was the search field: the page's only
                // control, wanting to go edge to edge; an icon next to it would turn a field
                // into a row with an appendage.
                //
                // The flaw is assuming the icon must sit **next to** the field. It now sits
                // above, in the same row as the page title - like Downloads and Library.
                //
                // **And in `BlurHeader`, not in its own row.** With its own spacing it
                // sat eight points lower than on the three other root pages; you see exactly
                // that when switching tabs. The component brings size, tracking and both
                // spacings - the same rule as everywhere: one role, one component.
                //
                // **The title exists wide and narrow, the header targets only narrow.** It
                // first existed only narrow - which made search on iPad what it had been on
                // iPhone before: the only root page without a title while Movies and Series
                // carry one. The header targets live wide in the sidebar, where they would
                // be a duplicate.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if term.isEmpty {
                            // **Rails only when Seerr works.** Without it the page is what it always was.
                            if seerr.ready, seerr.rails?.load == .content {
                                SeerrDiscoverView(model: model, flow: seerr)
                                if !last.isEmpty { recent }
                            } else if last.isEmpty { emptyHint } else { recent }
                        } else if hunts || (seerrPending && seerr.found == nil && seerr.ready), hit.isEmpty, !seerrShows {
                            // **No spinner.** While nothing is there yet, the grid stays in its shape;
                            // if results are already there, they stay instead of yielding to a spinner.
                            GridPlaceholder(
                                columns: Theme.columns(
                                    usableNow: frameRect.size.width - 2 * Theme.margin(wide: wide),
                                    wide: wide),
                                rails: 2)
                                .padding(.horizontal, Theme.margin(wide: wide))
                                .padding(.top, 12)
                                .transition(.opacity)
                        } else if disrupted, hit.isEmpty, !seerrShows {
                            // The same text as in the library, including the server address - one cause,
                            // one diagnosis.
                            EmptyState.serverDived(model, trouble: model.rustScreens.searchTrouble, retry: { searching(term) })
                                .padding(.top, 24)
                        } else if hit.isEmpty, !seerrShows {
                            // **Both empty, not only the library.** The own server has nothing, and Seerr has
                            // nothing either (or is not connected): the one empty state says so.
                            //
                            // **No button.** "Search via Seerr" would be a dummy: Seerr runs along with every
                            // word, so both have been checked already. The exit is the list below.
                            EmptyState(symbol: "magnifyingglass",
                                        headerLine: "Nichts gefunden zu \u{201E}\(term)\u{201C}",
                                        text: nothingText)
                                .padding(.top, 24)
                            if seerrOffline { offlineBox.padding(.top, 8) }
                            if !last.isEmpty { recent }
                        } else {
                            // Grouped by kind, like Plex: in the list you read title and kind at a glance.
                            let usableNow = frameRect.size.width - 2 * Theme.margin(wide: wide)
                            let own = ownHeading
                            let outside = seerrTiles
                            // **No heading without Seerr.** Someone who connected nothing should not
                            // read "On your server" and wonder where the other block is. The heading
                            // only counts when something really stands below - otherwise it announces
                            // an empty block.
                            if own > 0, !outside.isEmpty || seerrOffline {
                                blockTitle("Auf deinem Server", own)
                            }
                            group("Serien", hit.filter { $0.type == "Series" },
                                   usableNow: usableNow)
                            group("Filme", hit.filter { $0.type == "Movie" },
                                   usableNow: usableNow)
                            group("Folgen", hit.filter { $0.type == "Episode" },
                                   usableNow: usableNow)
                            group("Weiteres", hit.filter {
                                !["Series", "Movie", "Episode"].contains($0.type ?? "")
                            }, usableNow: usableNow)
                            people(usableNow: usableNow)
                            group(seerrGroupTitle(.collections), ownCollections, usableNow: usableNow)
                            if !outside.isEmpty {
                                blockTitle(verbatim: seerr.found?.blockTitle ?? "", outside.count)
                                    .padding(.top, 8)
                                seerrGrid(outside, usableNow: usableNow)
                            } else if seerrOffline {
                                blockTitle(verbatim: String(localized: "Noch nicht auf deinem Server"), 0)
                                    .padding(.top, 8)
                                offlineBox
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                // When scrolling through results the keyboard closes, as in the forms (`RootView`).
                .scrollDismissesKeyboard(.interactively)
                .contentMargins(.bottom, wide ? 24 : Theme.stripHeight + 12,
                                for: .scrollContent)
                // Tapping into the void closes the keyboard - otherwise you could not
                // leave the field at all.
                .simultaneousGesture(TapGesture().onEnded { inField = false })
                // Only the results area draws in, not the search field above - see `areaContent()`.
                // The look's glow, the same on every main page; goes up with the content.
                .lookGlow()
                .areaContent()
                .accountSwitchFade(model: model, ready: true, change: $accountSwitch)
                .onScrollGeometryChange(for: CGFloat.self) {
                    $0.contentOffset.y + $0.contentInsets.top
                } action: { _, new in
                    let clamped = min(max(new, 0), 30)
                    if clamped != scrolled { scrolled = clamped }
                }
                // The header is a safe-area inset, not an overlay (the reasoning is in `MainView`).
                .safeAreaInset(edge: .top, spacing: 0) { header }
            }
            }
            // Above the content, below everything else the page lays on - see `sectionBar()`.
            .sectionBar()
        }
        // First the keyboard, then the way back - as everywhere in iOS.
        //
        // Simultaneous, not exclusive: with `.gesture` the list below wins and the
        // swipe never arrived. So the gesture may run along without taking anything
        // from scrolling - it only evaluates what came out in the end.
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onEnded { gesture in
                    guard gesture.translation.width > 55,
                          abs(gesture.translation.height) < 55 else { return }
                    if inField { inField = false } else { back?() }
                }
        )
        // **The tab no longer opens the keyboard.**
        //
        // It opened by itself on entering the area - so you never landed on the search
        // page but always already in typing, and never saw what else the page offers.
        // Every other app on the device does it the other way: a tap takes you there,
        // you open the field yourself. On leaving, the keyboard still closes, otherwise
        // it would stay above the next area.
        .onChange(of: inField) { _, inside in if inside { searchMode = true } }

        // **On leaving only the keyboard closes, nothing else.**
        //
        // The search state survives the area change. Someone who checks where an
        // episode comes from at a hit and then goes back to Search wants to find their
        // search, not the empty page - otherwise you type the same word twice. It is
        // closed when you press the cross, and never otherwise.
        .onChange(of: active) { _, opened in if !opened { inField = false } }
        // **The second tap on the tab opens the field.** The first only brings you
        // here - see `tabStillTimes`.
        .onChange(of: anotherTime) { _, _ in if active { inField = true } }
        .onChange(of: term) { _, new in searching(new) }
        // Hits and term belong to the previous account.
        .onChange(of: model.accountSwitch) { _, _ in
            task?.cancel()
            term = ""
            seerrTask?.cancel()
            hit = []
            seerr.reset()
            seerrPending = false
            disrupted = false
            hunts = false
            searchMode = false
            historyLoad()
        }
        .onAppear { historyLoad() }
        // The rails of the empty page: read when the page opens and when Seerr is connected or removed.
        .task(id: "\(active)-\(model.seerr.connected)") {
            if active { await seerr.loadDiscover() }
        }
        // Watched/bookmark change on a detail page: the tile below should not show
        // the old state. The hits stay until the new ones are there.
        .catchUp(at: model.listenRefresh, front: active) {
            if !term.isEmpty { searching(term) }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ entries: [Item],
                        usableNow: CGFloat) -> some View {
        if !entries.isEmpty {
            // 15 semibold is in the type scale, the raw call is not - and "Series" is
            // not a heading but the label of the tiles below. So list row and not
            // `Theme.group`: the capitals belong to the three blocks, not their parts.
            Text(title)
                .growing(Theme.rowTitleSize, .semibold)
                .foregroundStyle(Theme.font)
                .padding(.horizontal, Theme.margin(wide: wide))
                .padding(.top, Theme.cardGap - 10)
                .padding(.bottom, 12)

            // Narrow a row list, wide a grid - TV does the same. A row with a 52 thumbnail
            // followed by 900 pt of nothing is no longer a list.
            //
            // **the search rule applies in both forms**: no hit starts playback, each leads to its page.
            // Previously what could be played started here - the comment said so, yet it was
            // the exception to the rule that applies everywhere else.
            if wide {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(),
                                                             spacing: Theme.tileSpacing),
                                         count: Theme.columns(usableNow: usableNow, wide: wide)),
                          alignment: .leading, spacing: Theme.gridRowGap) {
                    ForEach(entries) { item in
                        NavigationLink(value: item) {
                            PosterTile(model: model, item: item, width: nil,
                                       inquiry: item.groupedHitInfo)
                        }
                        .buttonStyle(Theme.PressButton())
                        // The usual way: open a hit. Only that fills "Recent searches", not just
                        // the Search key.
                        .simultaneousGesture(TapGesture().onEnded { remember(term) })
                        .tileMenu(item, model: model)
                    }
                }
                .padding(.horizontal, Theme.margin(wide: wide))
                .padding(.bottom, 10)
            } else {
                // **A grid when narrow too, no longer a row list.** With Seerr two blocks
                // stand below each other, and a poster tells at a glance whether a title is
                // there - a row with a 52 thumbnail cannot.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(),
                                                             spacing: Theme.tileSpacing),
                                         count: Theme.columns(usableNow: usableNow, wide: wide)),
                          // 20 as in Library, Watchlist and Genre - narrow search was the only one at 16.
                          alignment: .leading, spacing: Theme.gridRowGap) {
                    ForEach(entries) { item in
                        NavigationLink(value: item) {
                            PosterTile(model: model, item: item, width: nil,
                                       inquiry: item.groupedHitInfo)
                        }
                        .buttonStyle(Theme.PressButton())
                        // The usual way: open a hit. Only that fills "Recent searches", not just
                        // the Search key.
                        .simultaneousGesture(TapGesture().onEnded { remember(term) })
                        .tileMenu(item, model: model)
                    }
                }
                .padding(.horizontal, Theme.margin(wide: wide))
                .padding(.bottom, 10)
            }
        }
    }

    /// **The heading now also says how many.**
    ///
    /// Library and Watchlist carry a count on the right; it answers "am I through
    /// here?". Search lacked it - yet there it matters how much came at all, and
    /// for the second block incidentally how much Seerr has to offer.
    private func blockTitle(_ text: LocalizedStringKey, _ count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            category(text)
            Spacer(minLength: 8)
            if count > 0 { CountMark(count: count) }
        }
        .padding(.horizontal, Theme.margin(wide: wide))
        .padding(.top, 16)
        // 10 as under `Gruppentitel`: the size grew from 11 to 20, and 4 stuck
        // under a 20-size line.
        .padding(.bottom, 10)
    }

    private func blockTitle(verbatim text: String, _ count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: text)
                .font(Theme.section)
                .tracking(Theme.lockSection)
                .foregroundStyle(Theme.font)
            Spacer(minLength: 8)
            if count > 0 { CountMark(count: count) }
        }
        .padding(.horizontal, Theme.margin(wide: wide))
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    /// **The search heading - the same level as every group title.**
    ///
    /// It first used 13 semibold with 0.5 tracking, then 11 capitals from
    /// `Theme.group`. Both were a third version of the same heading: `Gruppentitel`
    /// has carried 20 semibold in sentence case since the rework, and a search
    /// heading has no other role than a settings heading. Tracking applies only to
    /// capitals anyway.
    ///
    /// **Still not the `Gruppentitel` component.** It brings its own page margin;
    /// the rows here already carry it, giving 36 instead of 18. And it stretches
    /// to full width - the count on the right would have no room. Size, weight,
    /// tracking and colour are reused, not the container.
    private func category(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(Theme.section)
            .tracking(Theme.lockSection)
            .foregroundStyle(Theme.font)
    }

    /// The tiles of titles the own server does not have, flat as the design draws them: the capsule says where
    /// each one stands, the line under the title says film or series.
    private func seerrGrid(_ cards: [SeerrCard], usableNow: CGFloat) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(),
                                                     spacing: Theme.tileSpacing),
                                 count: Theme.columns(usableNow: usableNow, wide: wide)),
                  // 20: the same grid row spacing as everywhere else.
                  alignment: .leading, spacing: Theme.gridRowGap) {
            ForEach(cards) { card in
                NavigationLink(value: card.route) { SeerrTile(card: card) }
                    .buttonStyle(Theme.PressRow())
                    .simultaneousGesture(TapGesture().onEnded { remember(term) })
            }
        }
        .padding(.horizontal, Theme.margin(wide: wide))
        .padding(.bottom, 10)
    }

    // MARK: Seerr part of the results

    /// What the library found by TMDB id is not drawn twice among the Seerr tiles.
    private var knownTmdb: Set<String> { Set(hit.compactMap { $0.providerIds?["Tmdb"] }) }

    /// Titles from Seerr that the own server does not have (the flow decides, shared by every platform).
    private var seerrTiles: [SeerrCard] { seerr.tiles(known: knownTmdb) }

    /// People of the Seerr search that the own server has (they open the person's page).
    private var ownPeople: [(card: SeerrCard, person: Person)] { seerr.ownPeople }

    /// Collections of the Seerr search that the own server has.
    private var ownCollections: [Item] { seerr.ownCollections }

    /// How many entries stand in the own-server block (the number beside its heading).
    private var ownHeading: Int { hit.count + ownPeople.count + ownCollections.count }

    /// The page has something from Seerr to draw: tiles, a person or a collection the library has.
    private var seerrShows: Bool { seerr.shows(known: knownTmdb) }

    /// Seerr is connected but did not answer: the box, not an empty block.
    private var seerrOffline: Bool { seerr.offline }

    private func seerrGroupTitle(_ kind: SwiftlyCore.SearchGroupKind) -> String { seerr.groupTitle(kind) }

    /// "Auch nicht bei Seerr." (the core's line) only when Seerr really answered with nothing.
    private var nothingText: LocalizedStringKey {
        if let line = seerr.nothingLine {
            return "\(line) Manchmal ist es nur ein Buchstabe."
        }
        return "Auf deinem Server steht dazu nichts. Manchmal ist es nur ein Buchstabe."
    }

    /// **One calm box, one way out.** The library results above are fine, so the box says so; the button asks
    /// Seerr again for the same word.
    private var offlineBox: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Seerr antwortet gerade nicht. Deine Bibliothek läuft normal.")
                .font(.app(size: 15))
                .foregroundStyle(Theme.fontQuiet)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 13)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.area, in: RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous))
            Button {
                retrySeerr()
            } label: {
                Text("Erneut versuchen")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, Theme.margin(wide: wide))
        .padding(.bottom, 10)
        .frame(maxWidth: wide ? Theme.readWidth : .infinity, alignment: .leading)
    }

    /// The people of the own library that Seerr found: round portraits, as in the cast.
    @ViewBuilder
    private func people(usableNow: CGFloat) -> some View {
        let list = ownPeople
        if !list.isEmpty {
            Text(seerrGroupTitle(.people))
                .growing(Theme.rowTitleSize, .semibold)
                .foregroundStyle(Theme.font)
                .padding(.horizontal, Theme.margin(wide: wide))
                .padding(.top, Theme.cardGap - 10)
                .padding(.bottom, 12)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 110), spacing: 14)],
                      alignment: .leading, spacing: Theme.gridRowGap) {
                ForEach(list, id: \.card.id) { pair in
                    NavigationLink(value: PersonRoute(person: pair.person, origin: nil)) {
                        CastTile(image: pair.card.poster.flatMap { URL(string: $0) },
                                 name: pair.card.title, role: nil)
                    }
                    .buttonStyle(Theme.PressButton())
                    .simultaneousGesture(TapGesture().onEnded { remember(term) })
                }
            }
            .padding(.horizontal, Theme.margin(wide: wide))
            .padding(.bottom, 10)
        }
    }

    private func retrySeerr() {
        seerrTask?.cancel()
        let clean = term.trimmingCharacters(in: .whitespaces)
        seerrPending = true
        seerrTask = Task {
            await seerr.search(clean)
            guard !Task.isCancelled else { return }
            seerrPending = false
        }
    }

    /// **What was searched last.**
    ///
    /// The space under the field was empty and carried a sentence explaining what
    /// a search field is. Someone standing here a second time mostly searches the
    /// same again - and a tapped word is faster than ten keystrokes.
    ///
    /// Tapping fills the field, and it then searches by itself. It explicitly does
    /// **not** open the keyboard: someone choosing from the list wants the result,
    /// not to keep typing.
    ///
    /// **It also stands under the empty state.** That gets no button because there
    /// is nothing to press - so the exit must be elsewhere, and a word already
    /// searched once is the shortest.
    private var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                // The same heading as the two result blocks - the `Gruppentitel` component
                // would have been a second page margin here, but the level is the same.
                category("Zuletzt gesucht")
                Spacer(minLength: 8)
                Button { historySet("") } label: {
                    Text("Löschen")
                        .growing(13, .medium)
                        .foregroundStyle(Theme.fontVeryQuiet)
                        // 44 pt hit area, the word stays small.
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Theme.PressRow())
            }
            .padding(.horizontal, Theme.margin(wide: wide))
            .padding(.top, 18)

            ForEach(Array(last.enumerated()), id: \.offset) { spot, word in
                Button {
                    term = word
                    inField = false
                } label: {
                    HStack(spacing: 12) {
                        Image(icon: "clock.arrow.circlepath")
                            .font(Theme.body)
                            .foregroundStyle(Theme.font)
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        Text(verbatim: word)
                            .growing(15, .semibold)
                            .foregroundStyle(Theme.font)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Theme.margin(wide: wide))
                    // **`minHeight`, not `height`.** The same mistake as once with `Schalter`: a
                    // fixed height on a text line clips the text as soon as someone enlarges the
                    // system font. The measure stays the minimum.
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(Theme.PressRow())

                if spot < last.count - 1 {
                    SeparatorLine().padding(.leading, Theme.separatorInset(wide: wide))
                }
            }
        }
        .frame(maxWidth: wide ? Theme.readWidth : .infinity, alignment: .leading)
    }

    /// **A notice, not an empty state - hence no emoji.**
    ///
    /// Nothing went wrong and nothing is empty: nobody has typed yet. A detective
    /// or popcorn would comment on a situation that does not exist. The brand rule:
    /// never, when nothing has been done yet.
    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(icon: "magnifyingglass", size: 44)
                // Used to be 34 in `.light`. That weight no longer exists - three weights,
                // regular is the lightest. And 44 is the size at which `Leerzustand` sets its
                // glyph: two glyphs of the same role, one measure.
                .font(.app(size: 44))
                .foregroundStyle(Theme.font)
            Text("Filme, Serien und Folgen durchsuchen")
                .growing(15)
                .foregroundStyle(Theme.fontQuiet)
        }
        // **Centered under the field, not centered in the window.**
        //
        // It sat in the middle of the full width while the field above sat left in its
        // reading width - the hint floated next to what it refers to. Left-aligned
        // was then the other extreme: glyph and sentence stuck to the edge of an empty
        // window. Now it gets the same column as the field and sits in its middle.
        .frame(maxWidth: wide ? Theme.readWidth : .infinity)
        .frame(maxWidth: .infinity, alignment: wide ? .leading : .center)
        .padding(.horizontal, wide ? Theme.margin(wide: true) : 0)
        .padding(.top, 70)
    }


    /// With a delay so not every keystroke triggers a request.
    private func searching(_ term: String) {
        task?.cancel()
        seerrTask?.cancel()
        let clean = term.trimmingCharacters(in: .whitespaces)
        // The threshold lives in the package so it is the same on all six versions -
        // it used to be typed individually everywhere.
        guard DisplayRules.searchTermFits(clean) else {
            hit = []
            seerr.reset()
            seerrPending = false
            // An earlier failure belongs to an earlier search.
            disrupted = false
            hunts = false
            return
        }
        hunts = true
        // **Side by side, not one after the other.** The own server is the reason anyone uses the app; it must
        // not wait for an extra. Seerr runs in its own task and joins the page when it answers.
        seerrPending = true
        seerrTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await seerr.search(clean)
            guard !Task.isCancelled else { return }
            seerrPending = false
        }
        task = Task {
            #if canImport(SwiftlyCore)
            // The Rust core debounces and searches (`AppModel.coreServes`).
            if model.coreServes {
                if let rustHits = await model.searchRust(clean) {
                    guard !Task.isCancelled else { return }
                    disrupted = false
                    hit = ListRules.withoutDouble(rustHits)
                    hunts = false
                    return
                }
                guard !Task.isCancelled else { return }
                // The core is the only search of this session: its failure is the server out of reach.
                disrupted = true
                hunts = false
                return
            } else {
                // CORE-GAP: the debounce and `model.search` below still serve tvOS/macOS.
                try? await Task.sleep(for: .milliseconds(300))
            }
            #else
            try? await Task.sleep(for: .milliseconds(300))
            #endif
            guard !Task.isCancelled else { return }
            let result = await model.search(clean)
            guard !Task.isCancelled else { return }
            disrupted = result == nil
            // Duplicate IDs make a tap miss.
            hit = ListRules.withoutDouble(result ?? [])
            hunts = false
        }
    }
}
