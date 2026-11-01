import JellyfinKit
import SwiftUI

/// **Search: the keyboard on the left, the hits next to it, live.**
///
/// Whoever types a word sees the hits after every letter and confirms nothing. The remote jumps from
/// the keyboard straight into the hits.
///
/// Deliberately not `.searchable`: on tvOS it brings Apple's own bar with keyboard and placement,
/// which fits neither the top bar nor the flat backdrop, and Android TV has nothing like it. The
/// keyboard is `TVSearchKeyboard`, the same grid on both TVs. The system keyboard only opens for the
/// mic key, because the remote's microphone belongs to it.
///
/// The full reasoning, the focus map and the states are in `Notizen/Mehrserver/TV-SUCHE-ENTWURF.md`.
struct SearchView: View {
    let model: AppModel
    /// Whether the section is currently open. When it turns true, focus goes to the keyboard.
    var active: Bool = false

    @State private var term = ""
    @State private var hit: [Item] = []
    /// What Seerr knows and the user's own server doesn't; empty if nothing is connected.
    @State private var seerrHit: [SeerrHit] = []
    /// An answer has arrived since the page was cleared.
    @State private var answered = false
    /// The first answer takes longer than 300 ms. Only then the placeholder shows; before that
    /// nothing flickers between two letters.
    @State private var waited = false
    /// The server did not answer, which is different from "nothing found".
    @State private var disrupted = false
    /// The running search. A new term cancels it, otherwise the answer to "Ga" occasionally
    /// arrived after the one to "Game" and overwrote it.
    @State private var searchRun: Task<Void, Never>?
    @State private var waitRun: Task<Void, Never>?
    /// The next change of the term is searched at once (a press on an earlier search).
    @State private var immediate = false

    /// What was searched for last: the same list as on the iPhone, the rule is in `SearchHistory`.
    /// With a remote every typed word is expensive; one you don't have to type again is worth more here than on a phone.
    @State private var lastRaw = ""
    private var last: [String] { SearchHistory.list(lastRaw) }

    @FocusState private var focused: SearchTarget?
    /// The key pressed last. Coming back from the hits, from the bar or from the speech input, focus
    /// lands here and not on whatever key happens to lie beside the tile.
    @State private var lastKey = "A"
    @State private var lastHit: String?

    private let top = "top"

    private var screen: SearchScreen {
        SearchScreen.state(term: term, historyCount: last.count,
                           hasHits: !hit.isEmpty || !seerrHit.isEmpty,
                           answered: answered, disrupted: disrupted, waited: waited)
    }

    private var hitIds: [String] { hit.map { "\($0.id)" } + seerrHit.map { "\($0.id)" } }

    var body: some View {
        HStack(alignment: .top, spacing: TVSpec.columnGap) {
            TVSearchKeyboard(term: $term, focus: $focused)
                .focusSection()
                .defaultFocus($focused, .key(lastKey), priority: .userInitiated)
                .padding(.top, Theme.contentTop - Theme.edgeTop)

            results
        }
        .padding(.leading, Theme.edgePage)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .defaultFocus($focused, .key(lastKey), priority: .userInitiated)
        // Whoever goes to "Search" wants to type, not first navigate to a key. So focus goes to the
        // last key at once.
        //
        // Focus must be handed on, not only assigned. On a section switch this page already exists:
        // it has been in the stack since the first visit and is only faded in. `defaultFocus` applies
        // on appearing, so it no longer works. And a bare assignment fizzles while focus is still in
        // the bar and tvOS has just set it there.
        .task(id: active) {
            guard active else { return }
            historyLoad()
            focused = .key(lastKey)
            // Once more, after tvOS has made its own move.
            try? await Task.sleep(for: .milliseconds(120))
            guard active, !isKey(focused) else { return }
            focused = .key(lastKey)
        }
        .onChange(of: focused) { old, new in
            switch new {
            case .key(let id): lastKey = id
            case .hit(let id): lastHit = id
            default: break
            }
            // Remembered is whoever leaves the keyboard with hits. Search runs while typing; a submit
            // like on the iPhone never happens: one types, sees the hits and goes right. That is
            // the moment something was searched for. "Ga", "Gam" on the way don't count.
            if isKey(old), case .hit = new, !hit.isEmpty {
                historySet(SearchHistory.remember(term, in: lastRaw))
            }
        }
        // One attempt per keystroke, but only the last counts. Every key press changes the term;
        // without a pause and cancellation each one sent a query to server and Seerr and the answers
        // returned in arbitrary order. 250 ms, as on the iPhone. No `.task(id: term)`: it would
        // run again on every return from a detail page and search the same thing once more.
        .onChange(of: term) { _, new in
            searchRun?.cancel()
            guard DisplayRules.searchTermFits(new) else {
                // Below two characters nothing is searched, and the hits give way to the history.
                waitRun?.cancel()
                withAnimation(Theme.reveal) {
                    hit = []
                    seerrHit = []
                    answered = false
                    disrupted = false
                    waited = false
                }
                return
            }
            let now = immediate
            immediate = false
            searchRun = Task {
                if !now { try? await Task.sleep(for: .milliseconds(250)) }
                guard !Task.isCancelled else { return }
                await searching()
            }
        }
        .onDisappear { searchRun?.cancel(); waitRun?.cancel() }
        // Hits and term belong to the previous account.
        .onChange(of: model.accountSwitch) { _, _ in
            searchRun?.cancel()
            waitRun?.cancel()
            term = ""
            hit = []
            seerrHit = []
            answered = false
            disrupted = false
            waited = false
            lastHit = nil
            historyLoad()
        }
        // Watched/watchlist state changed elsewhere: the tile shouldn't show the old state. Hits stay until new ones arrive.
        .onChange(of: model.listenRefresh) { _, _ in
            guard DisplayRules.searchTermFits(term) else { return }
            searchRun?.cancel()
            searchRun = Task { await searching() }
        }
        .onAppear { historyLoad() }
        .ignoresSafeArea(edges: .horizontal)
    }

    private func isKey(_ target: SearchTarget?) -> Bool {
        if case .key = target { return true }
        return false
    }

    // MARK: Results

    /// The right column. It scrolls on its own and ends at the lower edge of the bar.
    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(top)
                    content
                }
                .frame(width: SearchLayout.resultsWidth, alignment: .leading)
                // The scroll area starts 14 lower than the content should rest (see below).
                .padding(.top, -(topReserve - (Theme.contentTop - Theme.edgeTop)))
                .padding(.bottom, Theme.edgeTop)
                .animation(Theme.reveal, value: screen)
            }
            .frame(width: SearchLayout.resultsWidth)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            // The look's glow, the same on every main page; goes up with the content.
            .lookGlow()
            // Safe area, not padding and not `contentMargins`. Padding belongs to the content, which tvOS
            // scrolls away. What decides is how far tvOS pushes on a focus change, and only the scroll
            // area's safe area counts for that. Without it the scroll went just far enough for the tile
            // to be visible, and the block title above vanished under the wordmark.
            //
            // The title is 46 high and 36 above its tiles, and the bar ends at 128: with the system margin
            // (60) the reserve is 150. Less, and the title slips under the bar again when jumping to a
            // block. At rest the content sits 14 higher, at `Theme.contentTop`, level with the keyboard.
            .safeAreaInset(edge: .top) {
                Color.clear.frame(height: topReserve)
            }
            .focusSection()
            // Menu in the hits goes back to the keyboard, not to "Start": every letter has cost work
            // with the remote, and a Menu press must not throw them away. In the keyboard itself the
            // rule of all areas holds (`backStart` in `MainView`), because this handler only runs
            // while focus stands in this column.
            .onExitCommand {
                focused = .key(lastKey)
                withAnimation(Motion.change) { proxy.scrollTo(top, anchor: .top) }
            }
            // A new list while typing starts at the top. Standing in the hits it stays where the
            // tile is (the list then only changes through `listenRefresh`).
            .onChange(of: hitIds) { _, _ in
                guard isKey(focused) else { return }
                withAnimation(Motion.change) { proxy.scrollTo(top, anchor: .top) }
            }
        }
    }

    /// Block title (46) and its distance to the tiles (36).
    private var topReserve: CGFloat { Theme.barBottom - Theme.edgeTop + 46 + Theme.titleSpacing }

    @ViewBuilder
    private var content: some View {
        switch screen {
        case .blank:
            Color.clear.frame(height: 1)

        case .loading:
            // No spinner: the grid keeps its shape.
            VStack(alignment: .leading, spacing: Theme.titleSpacing) {
                LoadField(corner: Theme.cornerBar).frame(width: 300, height: 30)
                GridPlaceholder(columns: TVSpec.searchColumns, rails: 1)
            }
            .transition(.opacity)

        case .history:
            recent.transition(.opacity)

        case .start:
            note(symbol: "magnifyingglass",
                 sentence: "Titel, Serie oder Name. Ab zwei Zeichen wird gesucht.")
                .padding(.top, 240)
                .transition(.opacity)

        case .hits:
            hits.transition(.opacity)

        case .nothing:
            VStack(alignment: .leading, spacing: TVSpec.searchGroupGap) {
                // The way out is the keyboard next to it and the history below. The earlier "try again"
                // button is gone: the same word searched again finds nothing else.
                EmptyState(symbol: "magnifyingglass",
                           title: "Nichts gefunden zu „\(shortened(term))“",
                           hint: "Auf deinem Server steht dazu nichts. Manchmal ist es nur ein Buchstabe.")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: SearchLayout.resultsWidth)
                    .padding(.top, 70)
                if !last.isEmpty { recent }
            }
            .transition(.opacity)

        case .disrupted:
            // Failed is not "nothing found". `search` returns `nil` when the server doesn't answer.
            // Same text as in the library: one cause, one diagnosis. It also replaces old hits, which
            // belong to another word.
            EmptyState(
                symbol: "externaldrive.badge.xmark",
                title: "Server ist abgetaucht",
                hint: "\(model.serverAddress ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?",
                button: ("Erneut versuchen", { searchRun?.cancel(); searchRun = Task { await searching() } }))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: SearchLayout.resultsWidth)
                .padding(.top, 70)
                .transition(.opacity)
        }
    }

    /// A centred symbol with one quiet sentence, in the column of the hits.
    private func note(symbol: String, sentence: LocalizedStringKey) -> some View {
        VStack(spacing: 20) {
            Image(systemName: symbol)
                .font(.system(size: 88))
                .foregroundStyle(Theme.fontVeryQuiet)
                .accessibilityHidden(true)
            Text(sentence)
                .font(Theme.body)
                .foregroundStyle(Theme.fontVeryQuiet)
                .multilineTextAlignment(.center)
        }
        .frame(width: SearchLayout.resultsWidth)
    }

    /// Long words in the middle, so the head of "Nothing found" stays on two lines.
    private func shortened(_ word: String) -> String {
        let clean = word.trimmingCharacters(in: .whitespaces)
        guard clean.count > 32 else { return clean }
        return String(clean.prefix(14)) + "…" + String(clean.suffix(14))
    }

    // MARK: Hits

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Theme.gridColumn), count: TVSpec.searchColumns)
    }

    /// Block titles only when more than one block stands there; the rule is in the package.
    private var titles: Bool {
        let split = SearchGroups.split(hit, type: { $0.type })
        return SearchGroups.showsTitles(series: split.series.count, films: split.films.count,
                                        requests: seerrHit.count)
    }

    private var hits: some View {
        let split = SearchGroups.split(hit, type: { $0.type })
        // The tile focus lands on when coming from the keyboard: the last one, if the list still has it,
        // else the first of the first block.
        let ids = hit.map { "\($0.id)" }
        let landing = lastHit.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
        return VStack(alignment: .leading, spacing: Theme.railsSpacing) {
            block("Serien", split.series)
            block("Filme", split.films)
            if !seerrHit.isEmpty {
                VStack(alignment: .leading, spacing: Theme.titleSpacing) {
                    if titles { blockTitle("Kann angefragt werden", seerrHit.count) }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.latticeRow) {
                        ForEach(seerrHit) { t in
                            NavigationLink(value: t) { SeerrTile(hit: t) }
                                .buttonStyle(TileStyle())
                                .focused($focused, equals: .hit("\(t.id)"))
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        // A new list: same id stays and slides to its place, new ones fade in, old ones fade out.
        .animation(Motion.change, value: hitIds)
        .defaultFocus($focused, landing.map { .hit($0) }, priority: .userInitiated)
    }

    @ViewBuilder
    private func block(_ title: LocalizedStringKey, _ items: [Item]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Theme.titleSpacing) {
                if titles { blockTitle(title, items.count) }
                LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.latticeRow) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            TileContent(image: model.imageURL(for: item,
                                                              maxHeight: 600,
                                                              portrait: true),
                                         title: item.name,
                                         subline: item.hitInfo,
                                         progress: item.userData?
                                             .playedPercentage.map { $0 / 100 },
                                         mark: DisplayRules.tileMark(
                                            art: item.type,
                                            seasons: item.childCount,
                                            watched: item.userData?.played,
                                            openEpisodes: item.userData?
                                                .unplayedItemCount),
                                         symbolText: item.tileCharacter)
                        }
                        .buttonStyle(TileStyle())
                        .tileMenu(item, model: model)
                        .focused($focused, equals: .hit("\(item.id)"))
                    }
                }
            }
            .transition(.opacity)
        }
    }

    private func blockTitle(_ title: LocalizedStringKey, _ count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(title)
                .font(Theme.rail)
                .foregroundStyle(Theme.font)
            CountMark(count: count)
            Spacer(minLength: 0)
        }
    }

    // MARK: History

    /// What was searched for last: a card, one row per term, like on the iPhone.
    ///
    /// A press puts the word into the field and searches at once.
    ///
    /// "Clear history" is the last row, not a button above the card on the right as on the
    /// iPhone: a press down landed on "Clear" first instead of the first term, and a second press
    /// would have emptied the list.
    private var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupsTitle(text: "Zuletzt gesucht")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(last, id: \.self) { word in
                    Button {
                        historySet(SearchHistory.remember(word, in: lastRaw))
                        immediate = true
                        term = word
                        focused = .key(lastKey)
                    } label: {
                        HStack(spacing: 22) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: TVSpec.valueIcon, weight: .medium))
                                .foregroundStyle(Theme.fontVeryQuiet)
                                .frame(width: TVSpec.choiceCheckWidth)
                                .accessibilityHidden(true)
                            // Typed, so not a catalog text.
                            Text(verbatim: word)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(RowsStyle())
                    .focused($focused, equals: .recent(word))
                    SeparatorLine()
                }
                Button {
                    historySet("")
                    focused = .key(lastKey)
                } label: {
                    HStack(spacing: 22) {
                        Image(systemName: "trash")
                            .font(.system(size: TVSpec.valueIcon, weight: .medium))
                            .frame(width: TVSpec.choiceCheckWidth)
                            .accessibilityHidden(true)
                        Text("Verlauf löschen")
                    }
                }
                // Quiet through the style, not from inside: `RowsStyle(quiet:)` keeps it quiet at rest and
                // raises it as soon as one stands on it.
                .buttonStyle(RowsStyle(quiet: true))
            }
            .padding(TVSpec.listCardInset)
            .background(Theme.area, in: RoundedRectangle(cornerRadius: Theme.cornerArea, style: .continuous))
        }
        .frame(width: TVSpec.formWidth, alignment: .leading)
    }

    private func historyLoad() {
        lastRaw = SearchHistoryStore.load(account: model.session?.accountKey)
    }

    private func historySet(_ new: String) {
        lastRaw = new
        SearchHistoryStore.save(new, account: model.session?.accountKey)
    }

    // MARK: Searching

    // A hit's subline comes from `Item.hitInfo` in the package, the same rule as on
    // iPhone, iPad, Mac and Android ("Movie · 2008", with season count for series).

    private func searching() async {
        let word = term.trimmingCharacters(in: .whitespaces)
        // The same threshold as everywhere; the rule is in `DisplayRules`.
        guard DisplayRules.searchTermFits(word) else { return }
        // The placeholder only after 300 ms, and only while nothing at all is on screen. Old hits stay
        // untouched until the new ones are in: no dimming, no sign, no flicker per letter.
        waitRun?.cancel()
        if hit.isEmpty, seerrHit.isEmpty, !answered {
            waitRun = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                waited = true
            }
        }
        // Side by side, not one after the other. Seerr is an extra; if nothing comes from there or
        // it comes late, what the own server has still shows at once.
        async let ownOnes = model.search(word)
        async let foreignOnes = model.seerr.searching(word)
        let (a, b) = await (ownOnes, foreignOnes)
        // Overtaken: a newer term is already searching.
        guard !Task.isCancelled else { return }
        waitRun?.cancel()
        withAnimation(Motion.change) {
            // `nil` means failed, not empty.
            disrupted = a == nil
            // Without double IDs: a `ForEach` assigns by id, and the server occasionally returns the same title twice.
            hit = ListRules.withoutDouble(a ?? [])
            // What is already on the server belongs in the upper block, otherwise the same title would appear twice on the page.
            seerrHit = b.filter { !$0.state.alreadyPresent }
            answered = true
            waited = false
        }
    }
}
