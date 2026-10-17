import JellyfinKit
import SwiftUI

/// Search: field on top, hits as a grid below.
///
/// Deliberately not `.searchable`: on tvOS it brings Apple's own bar with keyboard and
/// placement, which fits neither the top bar nor the flat backdrop.
struct SearchView: View {
    let model: AppModel
    /// Whether the section is currently open. When it turns true, the keyboard opens by itself.
    var active: Bool = false

    @State private var term = ""
    @State private var hit: [Item] = []
    /// What Seerr knows and the user's own server doesn't; empty if nothing is connected.
    @State private var seerrHit: [SeerrHit] = []
    @State private var running = false
    @State private var searched = false
    /// The server did not answer, which is different from "nothing found".
    @State private var disrupted = false
    /// The running search. A new term cancels it, otherwise the answer to "Ga" occasionally
    /// arrived after the one to "Game" and overwrote it.
    @State private var searchRun: Task<Void, Never>?
    /// What was searched for last: the same list as on the iPhone, the rule is in `SearchHistory`.
    /// With a remote every typed word is expensive; one you don't have to type again is worth more here than on a phone.
    @AppStorage(SearchHistory.key) private var lastRaw = ""
    private var last: [String] { SearchHistory.list(lastRaw) }
    @FocusState private var atField: Bool

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Theme.gridColumn),
              count: Theme.gridColumns)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                // Field and information in one row, like the chip row of the library: field left, hit count right.
                HStack(alignment: .center, spacing: 40) {
                    InputField(placeholder: "Titel, Serie, Person", text: $term,
                                outer: $atField) {
                        lastRaw = SearchHistory.remember(term, in: lastRaw)
                        searchRun?.cancel()
                        searchRun = Task { await searching() }
                    }
                    .frame(width: 1000)

                    if !hit.isEmpty {
                        Text("\(hit.count) Treffer")
                            .font(Theme.small)
                            .foregroundStyle(Theme.fontVeryQuiet)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.edgePage)

                if running, hit.isEmpty {
                    // No spinner: the grid keeps its shape. If hits are already there, they stay instead of giving way to a spinner.
                    GridPlaceholder(rails: 1)
                        .padding(.horizontal, Theme.edgePage)
                        .padding(.top, 40)
                        .transition(.opacity)
                } else if disrupted, hit.isEmpty, !running {
                    // Failed is not "nothing found". `search` returns `nil` when the server doesn't answer;
                    // the `?? []` below turned that into an empty hit list and the page said the title doesn't
                    // exist. Same text as in the library: one cause, one diagnosis.
                    EmptyState(
                        symbol: "externaldrive.badge.xmark",
                        title: "Server ist abgetaucht",
                        hint: "\(model.serverAddress ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?",
                        button: ("Erneut versuchen", { Task { await searching() } }))
                        .frame(height: 460)
                } else if hit.isEmpty && searched, !running {
                    // A way out, not a dead-end sign; even more unpleasant with a remote than with a finger.
                    EmptyState(symbol: "magnifyingglass",
                                title: "Nichts gefunden",
                                hint: "Versuch es mit einem anderen Wort.",
                                button: ("Erneut versuchen", { Task { await searching() } }))
                        .frame(height: 460)
                } else if !searched {
                    if last.isEmpty {
                        // One sentence instead of black silence. Before the first input nothing stood here, a
                        // black screen with a glowing field. A suggestion shelf would be filler; one sentence says
                        // what the field accepts and when it starts searching.
                        Text("Titel, Serie oder Name. Ab zwei Zeichen wird gesucht.")
                            .font(Theme.body)
                            .foregroundStyle(Theme.fontVeryQuiet)
                            .padding(.horizontal, Theme.edgePage)
                            .padding(.top, 10)
                    } else {
                        recent
                    }
                } else if !hit.isEmpty {
                    LazyVGrid(columns: columns, alignment: .leading,
                              spacing: Theme.latticeRow) {
                        ForEach(hit) { item in
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
                        }
                    }
                    .padding(.horizontal, Theme.edgePage)
                    .scrollClipDisabled()
                }

                if !seerrHit.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 20) {
                        Text("Kann angefragt werden")
                            .font(Theme.rail)
                            .foregroundStyle(Theme.font)
                        CountMark(count: seerrHit.count)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Theme.edgePage)

                    LazyVGrid(columns: columns, alignment: .leading,
                              spacing: Theme.latticeRow) {
                        ForEach(seerrHit) { t in
                            NavigationLink(value: t) { SeerrTile(hit: t) }
                                .buttonStyle(TileStyle())
                        }
                    }
                    .padding(.horizontal, Theme.edgePage)
                    .scrollClipDisabled()
                }
            }
            .padding(.bottom, 60)
        }
        .scrollIndicators(.hidden)
        // Whoever goes to "Search" wants to type, not first navigate to a field. So focus goes there
        // at once, and tvOS opens the keyboard by itself.
        //
        // Focus must be handed on, not only assigned. On a section switch this page already exists:
        // it has been in the stack since the first visit and is only faded in. `defaultFocus` applies
        // on appearing, so it no longer works. And a bare assignment fizzles while focus is still in
        // the bar and tvOS has just set it there.
        //
        // This only became visible once the field turned white only in focus: before, it always lit
        // up and looked as if it had focus. The pill on the "Search" tab was the only place with the truth.
        .task(id: active) {
            guard active else { return }
            atField = true
            // Once more, after tvOS has made its own move.
            try? await Task.sleep(for: .milliseconds(120))
            guard active, !atField else { return }
            atField = true
        }
        // And explicitly as the default. The assignment above alone was not enough: focus stayed
        // on the "Search" tab in the bar. Only noticed once the field no longer is white all the time.
        .defaultFocus($atField, true, priority: .userInitiated)
        // Safe area, not padding and not `contentMargins`. Padding belongs to the content, which tvOS
        // scrolls away. `contentMargins` only sets the resting position. What decides is how far
        // tvOS pushes on a focus change, and only the scroll area's safe area counts for that. Without
        // it the scroll went just far enough for the tile to be visible, and the row title above
        // vanished under the wordmark.
        //
        // 150 is the minimum, not a matter of taste: system safe margin (60) plus 150 is 210, minus
        // row title (46) and its gap to the tile (36) leaves exactly the 128 of the bar's lower edge.
        // Less, and the title slips under it again when jumping to a row.
        //
        // The field starts at `Theme.contentTop`, like the topmost element of every other main page,
        // minus the top safe margin where the area begins.
        //
        // The earlier minimum of 150 held for rows with a title (46 and gap 36 kept free). The
        // search grid has no title above, only the field, and that should stay visible when jumping to a tile, no more.
        .safeAreaInset(edge: .top) {
            Color.clear.frame(height: Theme.contentTop - Theme.edgeTop)
        }
        // One attempt per keystroke, but only the last counts. The keyboard reports every letter;
        // without a pause and cancellation each one sent a query to server and Seerr and the answers
        // returned in arbitrary order. 250 ms, as on the iPhone. No `.task(id: term)`: it would
        // run again on every return from a detail page and search the same thing once more.
        .onChange(of: term) { _, new in
            searchRun?.cancel()
            guard !new.isEmpty else {
                hit = []
                seerrHit = []
                searched = false
                disrupted = false
                running = false
                return
            }
            searchRun = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await searching()
            }
        }
        .onDisappear { searchRun?.cancel() }
        // Hits and term belong to the previous account.
        .onChange(of: model.accountSwitch) { _, _ in
            searchRun?.cancel()
            term = ""
            hit = []
            seerrHit = []
            searched = false
            disrupted = false
            running = false
        }
        // Watched/watchlist state changed elsewhere: the tile shouldn't show the old state. Hits stay until new ones arrive.
        .onChange(of: model.listenRefresh) { _, _ in
            guard !term.isEmpty else { return }
            searchRun?.cancel()
            searchRun = Task { await searching() }
        }
        // Side margin: see `HomeView`. The system margin is dropped so `edgePage` does not double it.
        // Remembered is whoever leaves the field with hits. Search runs while typing here; a submit
        // like on the iPhone often never happens: one types, sees the hits and goes down. That is
        // the moment something was searched for. "Ga", "Gam" on the way don't count.
        .onChange(of: atField) { _, inField in
            guard !inField, !hit.isEmpty else { return }
            lastRaw = SearchHistory.remember(term, in: lastRaw)
        }
        .ignoresSafeArea(edges: .horizontal)
    }

    /// What was searched for last: a card below the field, one row per term, like on the iPhone.
    ///
    /// A press fills the field; search then runs by itself, as when typing.
    ///
    /// "Clear history" is the last row, not a button above the card on the right as on the
    /// iPhone. There it would sit right below the field's right end, and the focus engine
    /// searches geometrically: a press down landed on "Clear" first instead of the first term,
    /// and a second press would have emptied the list.
    private var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupsTitle(text: "Zuletzt gesucht")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(last, id: \.self) { word in
                    Button {
                        lastRaw = SearchHistory.remember(word, in: lastRaw)
                        term = word
                    } label: {
                        HStack(spacing: 22) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 26, weight: .medium))
                                .foregroundStyle(Theme.fontVeryQuiet)
                                .frame(width: 34)
                                .accessibilityHidden(true)
                            // Typed, so not a catalog text.
                            Text(verbatim: word)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(RowsStyle())
                    SeparatorLine()
                }
                Button { lastRaw = "" } label: {
                    HStack(spacing: 22) {
                        Image(systemName: "trash")
                            .font(.system(size: 26, weight: .medium))
                            .frame(width: 34)
                            .accessibilityHidden(true)
                        Text("Verlauf löschen")
                    }
                }
                // Quiet through the style, not from inside. The row used `schriftSehrLeise`, also in focus,
                // which is 3.59:1 on the focus surface. `RowsStyle(quiet:)` keeps it quiet at rest and
                // raises it as soon as one stands on it.
                .buttonStyle(RowsStyle(quiet: true))
            }
            .padding(10)
            .background(Theme.area, in: RoundedRectangle(cornerRadius: Theme.cornerTile, style: .continuous))
        }
        .frame(width: 1000, alignment: .leading)
        .padding(.horizontal, Theme.edgePage)
        .focusSection()
    }

    // A hit's subline comes from `Item.hitInfo` in the package, the same rule as on
    // iPhone, iPad, Mac and Android ("Movie · 2008", with season count for series). A narrower
    // `gattungUndJahr` of its own used to be here, the only platform with a different subline.

    private func searching() async {
        let word = term.trimmingCharacters(in: .whitespaces)
        // The same threshold as everywhere. `!wort.isEmpty` used to be here, so one letter fired a
        // query over half the library while the line above claimed "Search starts at two
        // characters". The rule is in `DisplayRules`.
        guard DisplayRules.searchTermFits(word) else { return }
        running = hit.isEmpty
        // Side by side, not one after the other. Seerr is an extra; if nothing comes from there or
        // it comes late, what the own server has still shows at once.
        async let ownOnes = model.search(word)
        async let foreignOnes = model.seerr.searching(word)
        let (a, b) = await (ownOnes, foreignOnes)
        // Overtaken: a newer term is already searching.
        guard !Task.isCancelled else { return }
        // Remove duplicate ids before they go into a `ForEach`. Reported: a press on a series
        // opened the one after next. `ForEach` assigns by id and the server occasionally returns
        // the same title twice. The iPhone version catches this; the guard was missing here.
        // `nil` means failed, not empty. The `?? []` alone turned a silent server into an empty hit
        // list, and the page claimed the title doesn't exist. The iPhone version distinguishes the two; here it was missing.
        disrupted = a == nil
        hit = ListRules.withoutDouble(a ?? [])
        // What is already on the server belongs in the upper block, otherwise the same title would appear twice on the page.
        seerrHit = b.filter { !$0.state.alreadyPresent }
        searched = true
        running = false
    }
}
