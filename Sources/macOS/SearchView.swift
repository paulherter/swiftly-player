import JellyfinKit
import SwiftUI

/// Search. No `.searchable`: on the Mac it brings its own bar, corners and
/// material. Same field as the sign-in screen, just wider.
struct SearchView: View {
    let model: AppModel
    @Environment(Navigator.self) private var navigator
    @Environment(\.section) private var section

    @State private var term = ""
    /// An account switch is in progress: content holds still, then appears staggered.
    @State private var change = false
    @State private var hit: [Item] = []
    /// What Seerr knows and the own server does not; empty if nothing is connected.
    @State private var seerrHit: [SeerrHit] = []
    @State private var searched = false
    /// The last search term; the empty-state text names this term, not whatever is
    /// currently in the field.
    @State private var searchedHandle = ""
    /// **`nil` means failed, `[]` means nothing found.** `model.search` returns the two
    /// separately; `a ?? []` here turned a network error into "nothing found".
    @State private var disrupted = false
    /// A request is running: show the grid placeholder instead of a spinner.
    @State private var loads = false
    @FocusState private var inField: Bool

    /// **Recent searches.** Stored on the device, not on the server: the list is a
    /// convenience, not part of the account.
    ///
    /// Recorded on submit, not while typing: typing "Ga", "Gam", "Game" is one search,
    /// not three. The rule lives in `SearchHistory`; TV and iPhone show the same list.
    @AppStorage(SearchHistory.key) private var lastRaw = ""

    private var last: [String] { SearchHistory.list(lastRaw) }

    /// **What there is to search.** Shown only while the field is empty and there is
    /// no history, otherwise a hint would sit above the thing it explains.
    ///
    /// Centered under the field, not in the window: the field is left-aligned at its
    /// own width, and a hint centered in the whole area would float away from what it
    /// refers to.
    private var emptyHint: some View {
        // **Use the shared component, not a second variant.** This used to be a glyph at
        // size 30 `.light`, a weight that is not on the scale, with no circle and its own
        // layout. The same file uses the component two lines further down.
        EmptyState(symbol: "magnifyingglass",
                    headerLine: "Filme, Serien und Folgen durchsuchen")
        .frame(maxWidth: Theme.formWidth)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 70)
    }

    /// "Zuletzt gesucht": same list as on iPhone and TV, here as rows in a card.
    private var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                // Same section header as above every other group; this was the third copy of the
                // same heading.
                GroupsTitle(text: "Zuletzt gesucht")
                Spacer(minLength: 8)
                Button { lastRaw = "" } label: {
                    Text("Löschen")
                        .font(Theme.body.weight(.medium))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(Theme.PressButton())
            }
            .padding(.top, 26)
            .padding(.bottom, 8)

            CardView {
                ForEach(Array(last.enumerated()), id: \.offset) { spot, word in
                    if spot > 0 { SheetLine().padding(.leading, Theme.separatorInsetCard) }
                    Button { term = word } label: {
                        ValuesRow(symbol: "clock.arrow.circlepath",
                                   title: Text(verbatim: word), hoverable: true)
                    }
                    .buttonStyle(Theme.PressRow())
                }
            }
        }
        .frame(maxWidth: Theme.readWidth, alignment: .leading)
    }

    /// Retry: same term, new attempt. Otherwise the user would have to append a
    /// character and delete it again.
    private func stillInTimes() {
        let word = term
        term = ""
        Task { @MainActor in term = word }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Theme.tileWidth, maximum: Theme.tileWidth),
                  spacing: Theme.tileSpacing, alignment: .topLeading)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Suche")
                    .font(Theme.titleLarge)
                    .tracking(Theme.lockTitle)
                    .foregroundStyle(Theme.font)

                InputRow(text: $term, symbol: "magnifyingglass",
                             placeholder: String(localized: "Titel, Serie, Person"),
                             completion: { lastRaw = SearchHistory.remember(term, in: lastRaw) })
                    .frame(maxWidth: Theme.formWidth)
                    .padding(.top, 14)
                    .focused($inField)

                // With nothing in the field: where the user left off. A click searches it again.
                if term.isEmpty {
                    if last.isEmpty { emptyHint } else { recent }
                }

                if loads, hit.isEmpty, seerrHit.isEmpty {
                    // **No spinner.** The grid is already shown in its final shape and is cross-faded
                    // as soon as the results arrive, as on iPhone and TV.
                    GridPlaceholder(columns: 6, rails: 2)
                        .padding(.top, 24)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                } else if !hit.isEmpty {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        ForEach(hit, id: \.id) { entryRecord in
                            Button { navigator.openIt(.title(entryRecord), in: section) } label: {
                                PosterCell(title: entryRecord.name,
                                             secondLine: entryRecord.hitInfo,
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
                    .padding(.top, 24)
                } else if searched, disrupted, !term.isEmpty, seerrHit.isEmpty {
                    // Same text as in the library, including the server address: one cause, one
                    // diagnosis.
                    EmptyState(
                        symbol: "externaldrive.badge.xmark",
                        headerLine: "Server ist abgetaucht",
                        text: "\(model.serverAddress ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?",
                        primaryButton: ("Erneut versuchen", { stillInTimes() }))
                        .padding(.top, 120)
                } else if searched, !term.isEmpty, seerrHit.isEmpty {
                    // **Both empty, not just the library.** With `hit.isEmpty` here, this branch
                    // would win as soon as the own server has nothing, and the Seerr block below would
                    // never be reached, which is exactly the case the integration exists for.
                    // Wording and symbol match iPhone: the search says what it found nothing for, and
                    // the second sentence softens it.
                    EmptyState(symbol: "magnifyingglass",
                                headerLine: "Nichts gefunden zu \u{201E}\(searchedHandle)\u{201C}",
                                text: "Auf deinem Server steht dazu nichts. Manchmal ist es nur ein Buchstabe.")
                        .padding(.top, 120)
                }

                if !seerrHit.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        // **Row heading, not all caps.** 13 semibold is on no scale (13 exists only as
                        // medium), and `Gruppentitel` already uses normal case; this was the third copy of
                        // the same heading.
                        Text("Kann angefragt werden")
                            .font(Theme.rail)
                            .tracking(Theme.lockRail)
                            .foregroundStyle(Theme.fontQuiet)
                        Spacer(minLength: 8)
                        CountMark(count: seerrHit.count)
                    }
                    .padding(.top, hit.isEmpty ? 30 : 40)

                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        ForEach(seerrHit) { t in
                            Button { navigator.openIt(.seerrTitle(t), in: section) } label: {
                                SeerrTile(hit: t)
                            }
                            .buttonStyle(Theme.PressButton())
                        }
                    }
                    .padding(.top, 18)
                }
            }
            .padding(.horizontal, Theme.edgeSpacing)
            .padding(.top, Theme.contentTop)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        .accountSwitchFade(model: model, ready: true, change: $change)
        // Term and results belong to the previous account.
        .onChange(of: model.accountSwitch) { _, _ in
            term = ""; hit = []; seerrHit = []
            searched = false; disrupted = false; loads = false
        }
        // **The milky bar at the top edge.** macOS 26 adds it over every scroll view by
        // itself; it is not in our code. Over the image it was barely visible, on a plain
        // background to the left it showed as a bar. Anything the framework adds unasked
        // has to be switched off just like anything we add ourselves.
        .pagesScroll()
        .onAppear { inField = true }
        .task(id: "\(term)|\(model.listenRefresh)") {
            // **The rule comes from the package, not from here.** This used to be
            // `term.count > 1`: same result but without trimming, so a space plus one letter
            // triggered a request on the Mac but not on iPhone, and the threshold would have
            // been changed in one place only.
            guard DisplayRules.searchTermFits(term) else {
                hit = []; seerrHit = []; searched = false
                disrupted = false; loads = false; return
            }
            // Debounce instead of querying on every keystroke.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            loads = true
            // **Own server first, Seerr after.** Seerr is an extra; whatever the own server
            // has appears immediately. The term is sent trimmed.
            let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
            async let foreignOnes = model.seerr.searching(clean)
            let a = await model.search(clean)
            // A cancelled run writes nothing, otherwise "server unreachable" or an empty area
            // would flash up for a moment.
            guard !Task.isCancelled else { return }
            // Drop duplicate ids before they go into a `ForEach`.
            disrupted = a == nil
            hit = ListRules.withoutDouble(a ?? [])
            searchedHandle = clean
            if !hit.isEmpty { searched = true }
            let b = await foreignOnes
            guard !Task.isCancelled else { return }
            // Anything already on the server belongs in the upper block.
            seerrHit = b.filter { !$0.state.alreadyPresent }
            searched = true
            loads = false
        }
        .onReceive(NotificationCenter.default.publisher(for: CommandPost.name)) { post in
            if CommandPost.receive(post) == .search { inField = true }
        }
    }
}
