import JellyfinKit
import SwiftUI

/// Full-text search across movies, series and episodes.
struct SearchView: View {
    let model: AppModel
    /// The area is currently open. The tab persists after the first visit, so
    /// `onAppear` is not enough - the field would only get focus the very first time.
    var active: Bool = true
    /// Swipe right when the keyboard is already closed: back to where you were.
    var back: (() -> Void)? = nil


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
    /// What Seerr knows and the own server does not have.
    ///
    /// **Own state, own task.** The two fetches run side by side; if Seerr returns
    /// nothing or late, what the own server has still shows immediately.
    @State private var seerrHit: [SeerrHit] = []
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

    /// The rule itself is in `SearchHistory` - TV shows the same list, and a second
    /// version would be a copied function.
    private var historyKey: String {
        SearchHistory.key(account: model.session?.accountKey)
    }

    private func historyLoad() {
        let store = UserDefaults.standard
        let key = historyKey
        if key != SearchHistory.key, store.object(forKey: key) == nil {
            store.set(store.string(forKey: SearchHistory.key) ?? "", forKey: key)
        }
        lastRaw = store.string(forKey: key) ?? ""
    }

    private func historySet(_ new: String) {
        lastRaw = new
        UserDefaults.standard.set(new, forKey: historyKey)
    }

    private func remember(_ word: String) {
        historySet(SearchHistory.remember(word, in: lastRaw))
    }

    var body: some View {
        ZStack {
            Theme.reason.ignoresSafeArea()

            GeometryReader { frameRect in
            // **The animation sits on the whole column, not the field.**
            //
            // On the field alone only the field moved: the results area below brings an
            // opaque background via `areaContent()`, and its frame jumped up without
            // transition when the header went away. What showed was a black edge that
            // jerks up at once and a field wandering out from behind it. Both belong to
            // the same motion - it is a rearrangement of the column, not the journey of
            // one component.
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
                if !searchMode {
                    BlurHeader {
                        // Centered so title and profile mark sit on one line - like every other root page.
                        HStack(alignment: .center, spacing: 0) {
                            Text("Suchen").font(Theme.titleLarge).tracking(Theme.lockTitle)
                            Spacer(minLength: 0)
                            if !wide {
                                HeaderTargets(name: model.session?.userName ?? "?",
                                          image: model.userImageURL())
                            }
                        }
                        .foregroundStyle(Theme.font)
                    }
                    // **Only fade out, do not slide away.**
                    //
                    // With `.move(edge: .top)` the header slid up out of the picture together with
                    // its `HeaderHistory` - and the gradient is at 0.98 at the top. What you saw was
                    // a black surface that popped briefly with the field wandering through behind
                    // it. The field moves up anyway once the header needs no space; the motion
                    // arises from layout and need not be driven additionally.
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
                            Image(systemName: "xmark")
                                .font(Theme.listTitle)
                                .foregroundStyle(Theme.fontQuiet)
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

                .padding(.horizontal, Theme.margin(wide: wide))
                // Narrow, `BlurHeader` above carries the top spacing; when it is gone
                // because of typing, the field takes it over.
                .padding(.top, wide ? Theme.headerTop
                                       + (windowButtons ? WindowButtons.height : 0)
                                     : (searchMode ? 8 + (windowButtons ? WindowButtons.height : 0) : 4))
                .padding(.bottom, 16)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if term.isEmpty {
                            if last.isEmpty { emptyHint } else { recent }
                        } else if hunts, hit.isEmpty, seerrHit.isEmpty {
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
                        } else if disrupted, hit.isEmpty, seerrHit.isEmpty {
                            // The same text as in the library, including the server address - one cause,
                            // one diagnosis.
                            EmptyState.serverDived(model, retry: { searching(term) })
                                .padding(.top, 24)
                        } else if hit.isEmpty, seerrHit.isEmpty {
                            // **Both empty, not only the library.** This used `hit.isEmpty`, and that
                            // branch won as soon as the own server had nothing - the Seerr block below
                            // was never reached. Exactly the case the whole integration is built for:
                            // "Blade Runner" is not here, and *therefore* you want to request it.

                            // **An empty state, not a grey line.** It used to be a sentence in 15 regular
                            // in the middle of nothing - the same situation as an empty watchlist, just
                            // in a second build. There is one, and it carries glyph, heading and text in
                            // one measure.
                            //
                            // The heading stays factual, the joke is in the second sentence - as the
                            // brand rules say under "Emoji".
                            //
                            // **And no button.** "Search via Seerr" would be a dummy: Seerr runs along
                            // with every word, so both have been checked already. The exit is the list
                            // below - that is why it stays instead of vanishing with the first letter.
                            EmptyState(symbol: "magnifyingglass",
                                        headerLine: "Nichts gefunden zu \u{201E}\(term)\u{201C}",
                                        text: "Auf deinem Server steht dazu nichts. Manchmal ist es nur ein Buchstabe.")
                                .padding(.top, 24)
                            if !last.isEmpty { recent }
                        } else {
                            // Grouped by kind, like Plex: in the list you read title and kind at a glance.
                            let usableNow = frameRect.size.width - 2 * Theme.margin(wide: wide)
                            // **No heading without Seerr.** Someone who connected nothing should not
                            // read "On your server" and wonder where the other block is. The heading
                            // only counts when something really stands below - otherwise it announces
                            // an empty block.
                            if !seerrHit.isEmpty, !hit.isEmpty {
                                blockTitle("Auf deinem Server", hit.count)
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
                            if !seerrHit.isEmpty {
                                // "Can be requested" did not say where. The counter block is called "On
                                // your server" - so this one should say which way the other is.
                                blockTitle("Über Seerr anfragen", seerrHit.count).padding(.top, 8)
                                seerrGrid(usableNow: usableNow)
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
            }
            .animation(Theme.sheetMotion, value: searchMode)
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
            hit = []
            seerrHit = []
            disrupted = false
            hunts = false
            searchMode = false
            historyLoad()
        }
        .onAppear { historyLoad() }
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
                .growing(15, .semibold)
                .foregroundStyle(Theme.fontQuiet)
                .padding(.horizontal, Theme.margin(wide: wide))
                .padding(.top, 14)
                .padding(.bottom, wide ? 10 : 6)

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
                          alignment: .leading, spacing: 20) {
                    ForEach(entries) { item in
                        NavigationLink(value: item) {
                            PosterTile(model: model, item: item, width: nil,
                                       inquiry: item.hitInfo)
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
                          alignment: .leading, spacing: 20) {
                    ForEach(entries) { item in
                        NavigationLink(value: item) {
                            PosterTile(model: model, item: item, width: nil,
                                       inquiry: item.hitInfo)
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
            .font(Theme.rail)
            .tracking(Theme.lockRail)
            .foregroundStyle(Theme.fontQuiet)
    }

    private func seerrGrid(usableNow: CGFloat) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(),
                                                     spacing: Theme.tileSpacing),
                                 count: Theme.columns(usableNow: usableNow, wide: wide)),
                  // 20: the same grid row spacing as everywhere else.
                  alignment: .leading, spacing: 20) {
            ForEach(seerrHit) { t in
                NavigationLink(value: t) { SeerrTile(hit: t) }
                    .buttonStyle(Theme.PressRow())
                    .simultaneousGesture(TapGesture().onEnded { remember(term) })
            }
        }
        .padding(.horizontal, Theme.margin(wide: wide))
        .padding(.bottom, 10)
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
                        Image(systemName: "clock.arrow.circlepath")
                            .font(Theme.body)
                            .foregroundStyle(Theme.fontVeryQuiet)
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
            Image(systemName: "magnifyingglass")
                // Used to be 34 in `.light`. That weight no longer exists - three weights,
                // regular is the lightest. And 44 is the size at which `Leerzustand` sets its
                // glyph: two glyphs of the same role, one measure.
                .font(.system(size: 44))
                .foregroundStyle(Theme.fontVeryQuiet)
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
        let clean = term.trimmingCharacters(in: .whitespaces)
        // The threshold lives in the package so it is the same on all six versions -
        // it used to be typed individually everywhere.
        guard DisplayRules.searchTermFits(clean) else {
            hit = []
            seerrHit = []
            // An earlier failure belongs to an earlier search.
            disrupted = false
            hunts = false
            return
        }
        hunts = true
        task = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            // **Side by side, not one after the other.** The own server is the reason
            // anyone uses the app; it must not wait for an extra. So what it has is shown first.
            async let foreign = model.seerr.searching(clean)
            let result = await model.search(clean)
            guard !Task.isCancelled else { return }
            disrupted = result == nil
            // Duplicate IDs make a tap miss.
            hit = ListRules.withoutDouble(result ?? [])
            hunts = false

            let toIt = await foreign
            guard !Task.isCancelled else { return }
            // What the own server already has does not belong in the lower block -
            // otherwise the same title would appear twice. Animated: if Seerr comes
            // later, the "On your server" heading would otherwise push all hits down
            // without transition.
            withAnimation(Theme.reveal) {
                seerrHit = toIt.filter { !$0.state.alreadyPresent }
            }
        }
    }
}
